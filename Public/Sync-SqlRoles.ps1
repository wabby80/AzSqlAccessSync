# Script-level params: no Mandatory/ParameterSet attributes so dot-sourcing during Import-Module
# does not prompt or throw. Validation happens inside the function's own param block.
param(
    [string]$EnvProfile,
    [switch]$WhatIf,
    [switch]$PassThru,
    [switch]$Force,
    [string]$Document
)

function Sync-SqlRoles {
    <#
    .SYNOPSIS
        Ensures the standing database roles defined in Roles/*.json exist on every database.

    .DESCRIPTION
        Reads role definition JSON files from the module's Roles folder, filters by Environment
        (from -EnvProfile), and applies each definition (CREATE ROLE, role memberships, EXECUTE and
        other GRANTs) to every non-system database on the target server — regardless of whether the
        role is already in use anywhere. Roles are a standing baseline, not tied to a specific
        database or login.

        Every statement is re-run unconditionally on every invocation rather than diffed against
        current state first: CREATE ROLE is guarded with IF NOT EXISTS in the generated SQL, and
        ALTER ROLE ... ADD MEMBER / GRANT are both idempotent in SQL Server (safe to repeat, no
        error if already applied) - so there's nothing to gain from a pre-fetch/diff step, unlike
        Sync-SqlUserAccess's per-login/per-database sync.

        This function does not remove memberships or grants: a grant or membership added outside
        these JSON files is left alone (no drift detection there). It does, however, detect and
        report — and with -Force, remove — custom database roles that exist in SQL but are not
        declared in any Roles/*.json file for this environment ("undocumented roles"), using
        sys.database_principals.is_fixed_role to tell a custom role apart from a built-in one
        (db_owner, db_datareader, etc. - always excluded, never candidates for removal).

        A role definition's optional "databases" field restricts it to specific databases; when
        omitted, the role applies to every non-system database on the server (the original
        behavior). This also narrows what counts as "documented" for undocumented-role detection:
        a role scoped to one database is not considered documented in any other database.
        master is not part of the default set; a role is applied there only when its "databases"
        lists master explicitly, and undocumented-role detection is not run in master.

        On a target that isn't Azure SQL Database (VM/on-prem SQL Server), grants that are
        server-scope permissions (e.g. "ALTER ANY CONNECTION") are not applied per database:
        they're granted once, in master, to a server role with the same name as the role. Adding
        logins to that server role is not done here. A custom server role that no longer has a
        server-scope grant in any Roles/*.json file for this environment is reported as
        undocumented, and dropped with -Force, same as undocumented database roles.

    .PARAMETER EnvProfile
        Path to a JSON profile file containing SqlServer and Environment (same profile files used
        by Sync-SqlUserAccess, e.g. Profiles/example.json).

    .PARAMETER WhatIf
        Prints what would be done without executing any SQL.

    .PARAMETER PassThru
        Returns a structured summary object (Mode, Status, Changes, Warnings, Errors,
        UndocumentedRoles) in addition to the normal console output. Intended for CI/scripted
        consumption.

    .PARAMETER Force
        Drops custom roles found in SQL that aren't declared in any Roles/*.json file for this
        environment. Without -Force, undocumented roles are only reported (console output and,
        with -PassThru, the summary's UndocumentedRoles field) — nothing is removed. Combine with
        -WhatIf to preview which roles would be dropped without dropping them.

    .PARAMETER Document
        Database name. Instead of syncing, writes every undocumented custom role in that one
        database (excluding fixed/built-in SQL roles) — with its current memberOf/grantExecute/
        grants — to a new Roles/<database>_<yyyy-MM-dd>_documented.json, pre-scoped to that
        database via "databases" and to the profile's own Environment via "acceptedenvironments"
        (the environment this was documented from is exactly the one it's already proven correct
        for). Read-only against SQL; a starting draft for review before it's renamed and folded in
        properly. Ignores -WhatIf/-Force.

    .EXAMPLE
        Sync-SqlRoles -EnvProfile .\Profiles\example.json -WhatIf

    .EXAMPLE
        Sync-SqlRoles -EnvProfile .\Profiles\example.json -Force -WhatIf

    .EXAMPLE
        Sync-SqlRoles -EnvProfile .\Profiles\example.json -Document MyAppDb
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EnvProfile,

        [switch]$WhatIf,
        [switch]$PassThru,
        [switch]$Force,
        [string]$Document
    )

    $script:SyncQueryErrors = [System.Collections.Generic.List[string]]::new()
    $script:SyncActions     = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Startup banner ---
    Write-Host "Starting Azure SQL Roles Sync`n" -ForegroundColor Green

    if (-not (Test-Path $EnvProfile)) {
        throw "Environment profile file not found: $EnvProfile"
    }
    $ep = Get-Content $EnvProfile -Raw | ConvertFrom-Json
    $SqlServer   = $ep.SqlServer
    $Environment = $ep.Environment

    Write-Host "Using Environment Profile: $EnvProfile" -ForegroundColor Cyan
    Write-Host "SQL Server:                $SqlServer"  -ForegroundColor Cyan
    Write-Host "Environment:               $Environment" -ForegroundColor Cyan
    Write-Host ''

    # Roles are a single shared definition set for the whole module, not per-environment-profile
    # config, so the folder is resolved relative to this script rather than read from the profile.
    $rolesFolderPath = Join-Path $PSScriptRoot '..\Roles'
    if (-not (Test-Path $rolesFolderPath)) {
        throw "Roles folder not found: $rolesFolderPath"
    }

    # --- Load role definitions matching this environment ---
    # Same two-level shape as Logins/*.json: acceptedenvironments applies to the whole file,
    # "roles" is always an array (even for a single role), so one file can define several.
    $roleFiles = Get-ChildItem -Path $rolesFolderPath -Filter *.json
    $roleDefs  = foreach ($file in $roleFiles) {
        $roleConfig = Get-Content $file.FullName -Raw | ConvertFrom-Json
        if ($roleConfig.acceptedenvironments -and ($Environment -in $roleConfig.acceptedenvironments)) {
            $roleConfig.roles
        }
    }

    if ($Document) {
        Write-Host "Documenting undocumented roles in '$Document'`n" -ForegroundColor Green
        $accessToken = Get-AzSqlToken

        $definedInDb = @($roleDefs | Where-Object { -not $_.databases -or ($Document -in $_.databases) } |
            Select-Object -ExpandProperty role)

        $customRoles = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $Document `
            -Query "SELECT name FROM sys.database_principals WHERE type = 'R' AND is_fixed_role = 0 AND name <> N'public'" |
            Select-Object -ExpandProperty name

        $toDocument = @($customRoles | Where-Object { $_ -notin $definedInDb })

        $documentedRoles = foreach ($roleName in $toDocument) {
            $memberOf = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $Document -Query @"
SELECT parent.name AS ParentRole
FROM sys.database_role_members drm
JOIN sys.database_principals member ON drm.member_principal_id = member.principal_id
JOIN sys.database_principals parent ON drm.role_principal_id = parent.principal_id
WHERE member.name = N'$roleName' AND member.type = 'R';
"@ | Select-Object -ExpandProperty ParentRole

            $grants = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $Document -Query @"
SELECT dp.permission_name AS PermissionName
FROM sys.database_permissions dp
JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
WHERE p.name = N'$roleName' AND dp.class = 0 AND dp.state = 'G';
"@ | Select-Object -ExpandProperty PermissionName

            [PSCustomObject]@{
                role         = $roleName
                databases    = @($Document)
                memberOf     = @($memberOf)
                grantExecute = [bool]('EXECUTE' -in $grants)
                grants       = @($grants | Where-Object { $_ -ne 'EXECUTE' })
            }
        }

        if (@($documentedRoles).Count -eq 0) {
            Write-Host "No undocumented custom roles found in '$Document'." -ForegroundColor Green
            if ($PassThru) { return [PSCustomObject]@{ Mode = 'Document'; Status = 'OK'; DocumentedFile = $null; Roles = @() } }
            return
        }

        $outFile = Join-Path $rolesFolderPath "$($Document)_$(Get-Date -Format 'yyyy-MM-dd')_documented.json"
        [PSCustomObject]@{
            acceptedenvironments = @($Environment)
            roles                = @($documentedRoles)
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding utf8

        Write-Host "Documented $(@($documentedRoles).Count) undocumented role(s) to $outFile" -ForegroundColor Cyan
        foreach ($r in $documentedRoles) { Write-Host "  - $($r.role)" -ForegroundColor Cyan }

        if ($PassThru) {
            return [PSCustomObject]@{
                Mode           = 'Document'
                Status         = 'OK'
                DocumentedFile = $outFile
                Roles          = @($documentedRoles | Select-Object -ExpandProperty role)
            }
        }
        return
    }

    if (-not $roleDefs) {
        Write-Host "No role JSON files in '$rolesFolderPath' match environment '$Environment'." -ForegroundColor Yellow
        $summary = [PSCustomObject]@{
            Mode              = if ($WhatIf) { 'WhatIf' } else { 'Sync' }
            Status            = 'OK'
            Changes           = @()
            Warnings          = @()
            Errors            = @()
            UndocumentedRoles = @()
        }
        if ($PassThru) { return $summary }
        return
    }

    $undocumentedRoles = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Auth ---
    $accessToken = Get-AzSqlToken

    $isAzureSqlServer = Test-AzureSqlServer -SqlServer $SqlServer -AccessToken $accessToken
    Write-Host "Azure SQL Database:        $isAzureSqlServer" -ForegroundColor Cyan
    Write-Host ''

    # --- Server-scope grants (VM/on-prem SQL Server only) ---
    # A server-scope permission (e.g. ALTER ANY CONNECTION) can't be granted to a database role and
    # can only be granted from master (Msg 4621), so on non-Azure-SQL-Database targets any such grant
    # in a role definition is applied once, in master, to a server role of the same name instead of
    # to the database role in every database. Which permissions are server-scope is read from the
    # engine itself rather than kept as a list here; names that also exist at database scope are
    # left out so they keep the per-database behavior. Applies server-wide regardless of the role's
    # "databases" scope. Azure SQL Database has no user-defined server roles, so nothing changes there.
    $serverScopePermissions = if ($isAzureSqlServer) { @() } else {
        @(Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Query @"
SELECT permission_name FROM sys.fn_builtin_permissions('SERVER')
EXCEPT
SELECT permission_name FROM sys.fn_builtin_permissions('DATABASE');
"@ | Select-Object -ExpandProperty permission_name)
    }

    $documentedServerRoles = [System.Collections.Generic.List[string]]::new()

    foreach ($roleDef in $roleDefs) {
        $roleName     = $roleDef.role
        $serverGrants = @($roleDef.grants | Where-Object { $_ -and $_ -in $serverScopePermissions })
        if ($serverGrants.Count -eq 0) { continue }
        $documentedServerRoles.Add($roleName)

        $createSql = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$roleName' AND type = 'R') " +
            "BEGIN CREATE SERVER ROLE [$roleName]; END;"

        if ($WhatIf) {
            Write-Host "[WhatIf] Would ensure server role [$roleName] exists in master" -ForegroundColor Cyan
            Add-SyncAction -Action 'EnsureServerRole' -Login $roleName -Database 'master' -Detail 'CREATE SERVER ROLE if not exists' -Planned $true
        } else {
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Query $createSql | Out-Null
            Add-SyncAction -Action 'EnsureServerRole' -Login $roleName -Database 'master' -Detail 'CREATE SERVER ROLE if not exists' -Planned $false
        }

        foreach ($grant in $serverGrants) {
            $detail = "GRANT $grant TO [$roleName] (server role)"
            if ($WhatIf) {
                Write-Host "[WhatIf] Would ensure '$grant' is granted to server role [$roleName] in master" -ForegroundColor Cyan
                Add-SyncAction -Action 'GrantServer' -Login $roleName -Database 'master' -Detail $detail -Planned $true
            } else {
                Write-Verbose "Ensuring '$grant' is granted to server role [$roleName] in master"
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Query "GRANT $grant TO [$roleName];" | Out-Null
                Add-SyncAction -Action 'GrantServer' -Login $roleName -Database 'master' -Detail $detail -Planned $false
            }
        }
    }

    # --- Undocumented server roles: same as the per-database check below, for server roles. A
    # custom server role that no role definition for this environment has a server-scope grant for
    # any more (the grant was removed from the JSON, or the whole role was) is reported, and dropped
    # with -Force. Fixed server roles (sysadmin, ##MS_...##, etc.) and 'public' are never candidates,
    # nor are the SQL IaaS Agent extension's own roles (e.g. SqlIaaSExtension_StatusReporting) -
    # dropping those breaks the extension on Azure VMs.
    if (-not $isAzureSqlServer) {
        $customServerRoles = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken `
            -Query "SELECT name FROM sys.server_principals WHERE type = 'R' AND is_fixed_role = 0 AND name <> N'public' AND name NOT LIKE N'##%' AND name NOT LIKE N'SqlIaaSExtension[_]%'" |
            Select-Object -ExpandProperty name

        foreach ($roleName in ($customServerRoles | Where-Object { $_ -notin $documentedServerRoles })) {
            $undocumentedRoles.Add([PSCustomObject]@{ Database = 'master'; Role = $roleName })

            if ($WhatIf) {
                $suffix = if ($Force) { '' } else { ' (if -Force''d)' }
                Write-Host "[WhatIf] Would drop undocumented server role [$roleName] in master$suffix" -ForegroundColor Cyan
                if ($Force) {
                    Add-SyncAction -Action 'DropServerRole' -Login $roleName -Database 'master' -Detail 'undocumented server role, -Force' -Planned $true
                }
            } elseif ($Force) {
                Write-Host "Dropping undocumented server role [$roleName] in master (no server-scope grant in any Roles/*.json)" -ForegroundColor Yellow
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Query "DROP SERVER ROLE [$roleName];" | Out-Null
                Add-SyncAction -Action 'DropServerRole' -Login $roleName -Database 'master' -Detail 'undocumented server role, -Force' -Planned $false
            } else {
                Write-Host "Undocumented server role [$roleName] in master (no server-scope grant in any Roles/*.json - rerun with -Force to drop)" -ForegroundColor Yellow
            }
        }
    }

    # --- Get all non-system databases on the server ---
    $allDbsOnServer = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken `
        -Query "SELECT name FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb')" |
        Select-Object -ExpandProperty name

    # master is never part of the default "every database" set, but a role that names it explicitly
    # in "databases" (e.g. for dbmanager/loginmanager on Azure SQL Database) is applied there too.
    $masterScopedRoleDefs = @($roleDefs | Where-Object { $_.databases -and ('master' -in $_.databases) })
    if ($masterScopedRoleDefs.Count -gt 0) {
        $allDbsOnServer = @('master') + @($allDbsOnServer)
    }

    $dbCount  = @($allDbsOnServer).Count
    $dbIndex  = 0

    foreach ($dbName in $allDbsOnServer) {
        $dbIndex++
        Write-Progress -Activity "Syncing SQL roles" -Status $dbName `
            -PercentComplete ([Math]::Round($dbIndex / $dbCount * 100))

        # Roles this database is in scope for: no "databases" field means every database (the
        # original behavior); otherwise only the databases explicitly listed. master only ever gets
        # the roles that list it explicitly.
        $roleDefsForDb = if ($dbName -eq 'master') { $masterScopedRoleDefs } else {
            @($roleDefs | Where-Object { -not $_.databases -or ($dbName -in $_.databases) })
        }

        foreach ($roleDef in $roleDefsForDb) {
            $roleName = $roleDef.role

            # CREATE ROLE - guarded in the SQL itself, re-run every time regardless of state.
            $createSql = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$roleName' AND type = 'R') " +
                "BEGIN CREATE ROLE [$roleName]; END;"

            if ($WhatIf) {
                Write-Host "[WhatIf] Would ensure role [$roleName] exists in $dbName" -ForegroundColor Cyan
                Add-SyncAction -Action 'EnsureRole' -Login $roleName -Database $dbName -Detail 'CREATE ROLE if not exists' -Planned $true
            } else {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName -Query $createSql | Out-Null
                Add-SyncAction -Action 'EnsureRole' -Login $roleName -Database $dbName -Detail 'CREATE ROLE if not exists' -Planned $false
            }

            # Role memberships (e.g. db_datareader, db_datawriter, db_ddladmin) - ALTER ROLE ADD
            # MEMBER is idempotent, safe to re-run even if already a member.
            foreach ($parentRole in $roleDef.memberOf) {
                $detail = "ALTER ROLE [$parentRole] ADD MEMBER [$roleName]"
                if ($WhatIf) {
                    Write-Host "[WhatIf] Would ensure [$roleName] is a member of [$parentRole] in $dbName" -ForegroundColor Cyan
                    Add-SyncAction -Action 'AddRoleMember' -Login $roleName -Database $dbName -Detail $detail -Planned $true
                } else {
                    Write-Verbose "Ensuring [$roleName] is a member of [$parentRole] in $dbName"
                    Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
                        -Query "ALTER ROLE [$parentRole] ADD MEMBER [$roleName];" | Out-Null
                    Add-SyncAction -Action 'AddRoleMember' -Login $roleName -Database $dbName -Detail $detail -Planned $false
                }
            }

            # Database-wide EXECUTE - GRANT is idempotent, safe to re-run even if already granted.
            if ($roleDef.grantExecute) {
                $detail = "GRANT EXECUTE TO [$roleName]"
                if ($WhatIf) {
                    Write-Host "[WhatIf] Would ensure EXECUTE is granted to [$roleName] in $dbName" -ForegroundColor Cyan
                    Add-SyncAction -Action 'GrantExecute' -Login $roleName -Database $dbName -Detail $detail -Planned $true
                } else {
                    Write-Verbose "Ensuring EXECUTE is granted to [$roleName] in $dbName"
                    Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
                        -Query "GRANT EXECUTE TO [$roleName];" | Out-Null
                    Add-SyncAction -Action 'GrantExecute' -Login $roleName -Database $dbName -Detail $detail -Planned $false
                }
            }

            # Any other database-level grants (e.g. "VIEW DATABASE STATE", "KILL DATABASE CONNECTION").
            # Server-scope grants were already applied in master above.
            foreach ($grant in ($roleDef.grants | Where-Object { $_ -and $_ -notin $serverScopePermissions })) {
                $detail = "GRANT $grant TO [$roleName]"
                if ($WhatIf) {
                    Write-Host "[WhatIf] Would ensure '$grant' is granted to [$roleName] in $dbName" -ForegroundColor Cyan
                    Add-SyncAction -Action 'Grant' -Login $roleName -Database $dbName -Detail $detail -Planned $true
                } else {
                    Write-Verbose "Ensuring '$grant' is granted to [$roleName] in $dbName"
                    Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
                        -Query "GRANT $grant TO [$roleName];" | Out-Null
                    Add-SyncAction -Action 'Grant' -Login $roleName -Database $dbName -Detail $detail -Planned $false
                }
            }
        }

        # --- Undocumented roles: custom database roles present in SQL but not declared for this
        # database in any Roles/*.json file for this environment (respecting each role's own
        # "databases" scope, via $roleDefsForDb above). is_fixed_role tells a built-in role
        # (db_owner, db_datareader, etc.) apart from a custom one; 'public' is excluded explicitly
        # since it inconsistently reports is_fixed_role across engine versions and is never a
        # candidate for removal regardless. Not run in master: master is only visited for the roles
        # scoped to it, and its other custom database roles are outside what these JSON files manage.
        if ($dbName -eq 'master') { continue }

        $definedRoleNamesForDb = @($roleDefsForDb | Select-Object -ExpandProperty role)
        $customRoles = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
            -Query "SELECT name FROM sys.database_principals WHERE type = 'R' AND is_fixed_role = 0 AND name <> N'public'" |
            Select-Object -ExpandProperty name

        foreach ($roleName in ($customRoles | Where-Object { $_ -notin $definedRoleNamesForDb })) {
            $undocumentedRoles.Add([PSCustomObject]@{ Database = $dbName; Role = $roleName })

            if ($WhatIf) {
                $suffix = if ($Force) { '' } else { ' (if -Force''d)' }
                Write-Host "[WhatIf] Would drop undocumented role [$roleName] in $dbName$suffix" -ForegroundColor Cyan
                if ($Force) {
                    Add-SyncAction -Action 'DropRole' -Login $roleName -Database $dbName -Detail 'undocumented role, -Force' -Planned $true
                }
            } elseif ($Force) {
                Write-Host "Dropping undocumented role [$roleName] in $dbName (not in any Roles/*.json)" -ForegroundColor Yellow
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName -Query "DROP ROLE [$roleName];" | Out-Null
                Add-SyncAction -Action 'DropRole' -Login $roleName -Database $dbName -Detail 'undocumented role, -Force' -Planned $false
            } else {
                Write-Host "Undocumented role [$roleName] in $dbName (not in any Roles/*.json - rerun with -Force to drop)" -ForegroundColor Yellow
            }
        }
    }

    Write-Progress -Activity "Syncing SQL roles" -Completed

    # --- Summary ---
    Write-Host "`n=== Sync Summary ===" -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host "Mode:    WhatIf — no changes made" -ForegroundColor Cyan
    }

    $summary = [PSCustomObject]@{
        Mode              = if ($WhatIf) { 'WhatIf' } else { 'Sync' }
        Status            = if ($script:SyncQueryErrors.Count -eq 0) { 'OK' } else { 'FAILED' }
        Changes           = @($script:SyncActions | Where-Object { $_.Severity -eq 'Change' })
        Warnings          = @($script:SyncActions | Where-Object { $_.Severity -eq 'Warning' })
        Errors            = @($script:SyncQueryErrors)
        UndocumentedRoles = @($undocumentedRoles)
    }

    if ($undocumentedRoles.Count -gt 0) {
        Write-Host "Undocumented roles: $($undocumentedRoles.Count)$(if (-not $Force) { ' (not removed - rerun with -Force to drop)' })" -ForegroundColor Yellow
        foreach ($u in $undocumentedRoles) {
            Write-Host "  - [$($u.Role)] in $($u.Database)" -ForegroundColor Yellow
        }
    }

    if ($script:SyncQueryErrors.Count -eq 0) {
        Write-Host "Status:  OK" -ForegroundColor Green
    } else {
        Write-Host "Status:  FAILED" -ForegroundColor Red
        Write-Host "Errors:  $($script:SyncQueryErrors.Count)" -ForegroundColor Red
        foreach ($err in $script:SyncQueryErrors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
        if ($PassThru) { $summary }
        throw "Sync completed with $($script:SyncQueryErrors.Count) SQL query error(s). See output above for details."
    }

    if ($PassThru) { $summary }
}

# Self-invoke when executed directly as a script (not dot-sourced by the module).
# Loads private functions first since the module context is not available in standalone mode.
if ($MyInvocation.InvocationName -ne '.') {
    Get-ChildItem -Path "$PSScriptRoot\..\Private\*.ps1" | ForEach-Object { . $_.FullName }
    Sync-SqlRoles @PSBoundParameters
}
