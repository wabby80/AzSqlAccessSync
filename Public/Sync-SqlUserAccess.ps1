# Script-level params: no Mandatory/ParameterSet attributes so dot-sourcing during Import-Module
# does not prompt or throw. Validation happens inside the function's own param block.
param(
    [string]$LoginsFolderPath,
    [string]$SqlServer,
    [string]$Environment,
    [string]$EnvProfile,
    [Alias('Database')] [string]$OneDatabase,
    [string]$Username,
    [string]$RemoveLogin,
    [switch]$Verify,
    [switch]$WhatIf,
    [switch]$Reconnect,
    [switch]$PassThru
)

function Sync-SqlUserAccess {
    <#
    .SYNOPSIS
        Syncs Azure SQL logins, users, roles, and permissions from JSON files for a given environment.

    .DESCRIPTION
        Reads login JSON files from LoginsFolderPath, filters by Environment, and enforces that state
        against the target SQL server — creating logins/users, assigning roles and VIEW permissions,
        and removing anything present in SQL that is not defined in JSON.

        Supports -Verify (skip sync, report only) and -WhatIf (print actions without executing).
        SQL login creation is intentionally skipped — passwords must not be stored in JSON.

    .PARAMETER LoginsFolderPath
        Path to the folder containing per-login JSON files.

    .PARAMETER SqlServer
        The Azure SQL Server FQDN.

    .PARAMETER Environment
        The environment to match against "acceptedenvironments" in each JSON file (e.g. 'DEV', 'PROD').

    .PARAMETER EnvProfile
        Path to a JSON profile file containing LoginsFolderPath, SqlServer, Environment, and optional LoginIgnoreList.

    .PARAMETER OneDatabase
        Limits operations to a single database. Verification report is skipped when this is set.

    .PARAMETER RemoveLogin
        Drops server-level logins that are present in SQL, not declared in any JSON file, and have
        no access anywhere (i.e. present in both the "not defined in JSON" and "no database user
        and no server-level access" drift lists): not a system login (sa, ##...##), not a user in
        any database on the server, no server role membership, no server permission beyond
        CONNECT SQL, and not the owner of a database or SQL Agent job. Skipped if any SQL query in
        the run failed, since eligibility then can't be trusted. Pass 'ALL' to drop every such login, or an
        explicit login name to drop just that one. Requires the drift report, so cannot be combined
        with -Username or -Database. Skipped (with a message) when -Verify is set. Honors -WhatIf.

    .PARAMETER Verify
        Skips the sync loop entirely and only runs the drift report.

    .PARAMETER WhatIf
        Prints what would be done without executing any SQL.

    .PARAMETER Reconnect
        Clears the current Azure context and forces re-authentication.

    .PARAMETER PassThru
        Returns a structured summary object (Mode, Status, Changes, Warnings, Errors, Drift) in
        addition to the normal console output. Intended for CI/scripted consumption, e.g.
        `$result = Sync-SqlUserAccess ... -PassThru; $result | ConvertTo-Json`.

    .EXAMPLE
        Sync-SqlUserAccess -LoginsFolderPath './Logins' -SqlServer 'myserver.database.windows.net' -Environment 'DEV' -Verify

    .EXAMPLE
        Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -OneDatabase MyAppDb -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$LoginsFolderPath,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$SqlServer,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$Environment,

        [Parameter(Mandatory, ParameterSetName = 'Profile')]
        [string]$EnvProfile,

        [Parameter(Mandatory = $false)]
        [Alias('Database')]
        [string]$OneDatabase,

        [Parameter(Mandatory = $false)]
        [string]$Username,

        [Parameter(Mandatory = $false)]
        [string]$RemoveLogin,

        [switch]$Verify,
        [switch]$WhatIf,
        [switch]$Reconnect,
        [switch]$PassThru
    )

    $script:SyncQueryErrors = [System.Collections.Generic.List[string]]::new()
    $script:SyncActions     = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Startup banner ---
    Write-Host "Starting Azure SQL User Access Sync`n" -ForegroundColor Green

    $loginIgnoreList = @()

    if ($PSCmdlet.ParameterSetName -eq 'Profile') {
        if (-not (Test-Path $EnvProfile)) {
            throw "Environment profile file not found: $EnvProfile"
        }
        $ep = Get-Content $EnvProfile -Raw | ConvertFrom-Json
        Write-Host "Using Environment Profile: $EnvProfile"    -ForegroundColor Cyan
        Write-Host "Logins Folder Path:        $($ep.LoginsFolderPath)" -ForegroundColor Cyan
        Write-Host "SQL Server:                $($ep.SqlServer)"        -ForegroundColor Cyan
        Write-Host "Environment:               $($ep.Environment)"      -ForegroundColor Cyan

        $profileDir       = Split-Path -Parent (Resolve-Path $EnvProfile)
        $LoginsFolderPath = if ([System.IO.Path]::IsPathRooted($ep.LoginsFolderPath)) {
            $ep.LoginsFolderPath
        } else {
            Join-Path $profileDir $ep.LoginsFolderPath
        }
        $SqlServer        = $ep.SqlServer
        $Environment      = $ep.Environment
        if ($ep.LoginIgnoreList) { $loginIgnoreList = $ep.LoginIgnoreList }
    } else {
        Write-Host "Logins Folder Path:        $LoginsFolderPath" -ForegroundColor Cyan
        Write-Host "SQL Server:                $SqlServer"        -ForegroundColor Cyan
        Write-Host "Environment:               $Environment"      -ForegroundColor Cyan
    }

    if ($OneDatabase) { Write-Host "Database (filtered):       $OneDatabase" -ForegroundColor Cyan }
    if ($Username)    { Write-Host "Login (filtered):          $Username"    -ForegroundColor Cyan }
    Write-Host ''

    # --- Auth & config ---
    $accessToken      = Get-AzSqlToken -Reconnect:$Reconnect
    $isAzureSqlServer = Test-AzureSqlServer -SqlServer $SqlServer -AccessToken $accessToken
    Write-Host "Azure SQL Database:        $isAzureSqlServer" -ForegroundColor Cyan
    Write-Host ''

    $allLogins = Import-LoginConfig -LoginsFolderPath $LoginsFolderPath -Environment $Environment -IgnoreList $loginIgnoreList

    if ($Username) {
        $allLogins = $allLogins | Where-Object { $_.login -eq $Username }
        if (-not $allLogins) {
            throw "Login '$Username' is not defined in JSON for environment '$Environment'."
        }
    }

    # --- Get all non-system databases on the server ---
    $realDbsOnServer = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken `
        -Query "SELECT name FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb')" |
        Select-Object -ExpandProperty name

    $allDbsOnServer = if ($OneDatabase) {
        if ($OneDatabase -notin $realDbsOnServer) {
            Write-Host "ERROR: Database '$OneDatabase' does not exist on server '$SqlServer'." -ForegroundColor Red
            throw "Database '$OneDatabase' does not exist on server '$SqlServer'."
        }
        @($OneDatabase)
    } else {
        $realDbsOnServer
    }

    # --- Report databases defined in JSON that don't exist on this server ---
    if (-not $OneDatabase) {
        $dbsInJson  = $allLogins | ForEach-Object { $_.databases } | ForEach-Object { $_.database } |
            Where-Object { $_ -notin @('master', 'msdb') } | Select-Object -Unique
        $missingDbs = $dbsInJson | Where-Object { $_ -notin $allDbsOnServer }
        if ($missingDbs) {
            foreach ($db in ($missingDbs | Sort-Object)) {
                Write-Host "INFO: Database '$db' is defined in JSON but does not exist on this server — skipping." -ForegroundColor DarkGray
            }
            Write-Host ''
        }
    }

    # --- Sync ---
    if (-not $Verify) {
        $loginCount = @($allLogins).Count
        $loginIndex = 0

        # Single upfront read of current SQL state, reused for every login below instead of
        # each login/role/permission issuing its own existence/membership query.
        # 'master' is included even though it's excluded from $allDbsOnServer (a system database),
        # because logins can declare server-role grants against it — same special case $dbsForLogin
        # already carves out above. 'msdb' is only added on non-Azure-SQL-Database targets (VM/
        # on-prem/Managed Instance) — Azure SQL Database has no real msdb reachable via AAD token
        # auth, so including it there just produces login-failure noise (and errors) for nothing.
        $specialDatabases = if ($isAzureSqlServer) { @('master') } else { @('master', 'msdb') }
        $snapshotDatabases = @($allDbsOnServer) + $specialDatabases | Select-Object -Unique
        $accessSnapshot = Get-SqlAccessSnapshot -SqlServer $SqlServer -AccessToken $accessToken -AllDatabasesOnServer $snapshotDatabases

        foreach ($login in $allLogins) {
            $loginIndex++
            Write-Progress -Activity "Syncing SQL access" -Status $login.login `
                -PercentComplete ([Math]::Round($loginIndex / $loginCount * 100))

            $dbsForLogin = if ($OneDatabase) {
                $login.databases | Where-Object { $_.database -eq $OneDatabase }
            } else {
                $login.databases | Where-Object { $_.database -in $specialDatabases -or $_.database -in $allDbsOnServer }
            }

            if (-not $dbsForLogin) { continue }

            # Ensure server-level login exists
            $loginReady = Sync-SqlServerLogin -SqlServer $SqlServer -AccessToken $accessToken -Login $login -WhatIf $WhatIf.IsPresent
            if (-not $loginReady -and -not $WhatIf) { continue }

            # Sync each database
            foreach ($db in $dbsForLogin) {
                Write-Progress -Activity "Syncing SQL access" -Status $login.login `
                    -CurrentOperation $db.database -PercentComplete ([Math]::Round($loginIndex / $loginCount * 100))

                if ($accessSnapshot.OwnerByDb[$db.database] -eq $login.login) {
                    Write-Host "INFO: $($login.login) is already owner of $($db.database) - skipping (dbo already covers this)" -ForegroundColor DarkGray
                    continue
                }

                Sync-SqlDatabaseUser -SqlServer $SqlServer -AccessToken $accessToken `
                    -Login $login -Database $db.database -WhatIf $WhatIf.IsPresent

                if ($db.roles) {
                    Sync-SqlRoleMembership -SqlServer $SqlServer -AccessToken $accessToken `
                        -LoginName $login.login -Database $db.database -DesiredRoles $db.roles -Snapshot $accessSnapshot -WhatIf $WhatIf.IsPresent
                }

                if ($db.grantView) {
                    Sync-SqlViewPermission -SqlServer $SqlServer -AccessToken $accessToken `
                        -LoginName $login.login -Database $db.database -DesiredPermissions $db.grantView -Snapshot $accessSnapshot -WhatIf $WhatIf.IsPresent
                }

                if ($db.grantExecute) {
                    Sync-SqlExecutePermission -SqlServer $SqlServer -AccessToken $accessToken `
                        -LoginName $login.login -Database $db.database -DesiredPermissions $db.grantExecute -Snapshot $accessSnapshot -WhatIf $WhatIf.IsPresent
                }
            }

            # Remove this login from DBs/roles/permissions not in JSON
            Remove-SqlAccessDrift -SqlServer $SqlServer -AccessToken $accessToken `
                -Login $login -AllDatabasesOnServer $allDbsOnServer -Snapshot $accessSnapshot -WhatIf $WhatIf.IsPresent
        }

        Write-Progress -Activity "Syncing SQL access" -Completed

        # Remove DB users that exist in SQL but have no entry in JSON at all.
        # Skipped when -Username is set — bulk removal is not safe when syncing a single login.
        if (-not $Username) {
            $dbNamesInScope = if ($OneDatabase) {
                @($OneDatabase) | Where-Object { $_ -ne 'master' }
            } else {
                $allDbsOnServer
            }

            foreach ($dbName in $dbNamesInScope) {
                $dbUsers = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
                    -Query "SELECT name FROM sys.database_principals WHERE type IN ('E','S','X') AND name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys') AND name NOT LIKE '##%'" |
                    Select-Object -ExpandProperty name

                foreach ($dbUser in $dbUsers) {
                    $inJson = $allLogins | Where-Object {
                        $_.login -eq $dbUser -and ($_.databases | Where-Object { $_.database -eq $dbName })
                    }
                    if (-not $inJson) {
                        if ($WhatIf) {
                            Write-Host "[WhatIf] Would remove user $dbUser from $dbName (not defined in JSON)" -ForegroundColor Cyan
                            Add-SyncAction -Action 'RemoveUser' -Login $dbUser -Database $dbName -Detail 'not defined in JSON' -Planned $true
                        } else {
                            Write-Host "Removing user $dbUser from $dbName (not defined in JSON)" -ForegroundColor Yellow
                            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $accessToken -Database $dbName `
                                -Query "DROP USER [$dbUser];"
                            Add-SyncAction -Action 'RemoveUser' -Login $dbUser -Database $dbName -Detail 'not defined in JSON' -Planned $false
                        }
                    }
                }
            }
        }
    }

    # --- Drift report ---
    $driftReport = if ($Username) {
        Write-Host "`nSkipping verification since -Username is specified." -ForegroundColor Yellow
        $null
    } elseif ($OneDatabase) {
        Write-Host "`nSkipping verification of extra users/logins since -Database parameter is specified." -ForegroundColor Yellow
        $null
    } else {
        Get-SqlAccessDriftReport -SqlServer $SqlServer -AccessToken $accessToken -AllLogins $allLogins -AllDatabasesOnServer $allDbsOnServer -IgnoreList $loginIgnoreList -IsAzureSqlServer $isAzureSqlServer
    }

    # --- Remove orphaned logins ---
    if ($RemoveLogin) {
        if ($Verify) {
            Write-Host "`nSkipping login removal since -Verify is specified." -ForegroundColor Yellow
        } elseif (-not $driftReport) {
            throw "-RemoveLogin requires the drift report; it cannot be combined with -Username or -Database."
        } elseif ($script:SyncQueryErrors.Count -gt 0) {
            # A failed query (e.g. the server-role or job-owner lookup) makes a login look like it
            # has no access when it might - never drop logins on incomplete data.
            Write-Host "`nSkipping login removal: $($script:SyncQueryErrors.Count) SQL query error(s) earlier in this run mean eligibility can't be trusted." -ForegroundColor Red
        } else {
            $removableLogins = @($driftReport.LoginsNotInJson | Where-Object { $_ -in $driftReport.LoginsWithNoDb })

            $loginsToRemove = if ($RemoveLogin -eq 'ALL') {
                $removableLogins
            } elseif ($RemoveLogin -in $removableLogins) {
                @($RemoveLogin)
            } elseif ($RemoveLogin -notin $driftReport.AllServerLogins) {
                Write-Host "`nLogin '$RemoveLogin' not found on server (already removed or never existed) — skipping." -ForegroundColor Yellow
                @()
            } else {
                throw "Login '$RemoveLogin' is not eligible for removal — it must be present in SQL, absent from JSON, not a system login, a user in no database, hold no server role or server permission, and own no database or job."
            }

            if ($loginsToRemove.Count -gt 0) {
                Write-Host ''
                Remove-SqlOrphanedLogin -SqlServer $SqlServer -AccessToken $accessToken -LoginNames $loginsToRemove -WhatIf $WhatIf.IsPresent
            } elseif ($RemoveLogin -eq 'ALL') {
                Write-Host "`nNo logins eligible for removal." -ForegroundColor DarkGray
            }
        }
    }

    # --- Summary ---
    Write-Host "`n=== Sync Summary ===" -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host "Mode:    WhatIf — no changes made" -ForegroundColor Cyan
    }

    $summary = [PSCustomObject]@{
        Mode     = if ($WhatIf) { 'WhatIf' } elseif ($Verify) { 'Verify' } else { 'Sync' }
        Status   = if ($script:SyncQueryErrors.Count -eq 0) { 'OK' } else { 'FAILED' }
        Changes  = @($script:SyncActions | Where-Object { $_.Severity -eq 'Change' })
        Warnings = @($script:SyncActions | Where-Object { $_.Severity -eq 'Warning' })
        Errors   = @($script:SyncQueryErrors)
        Drift    = $driftReport
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
    Sync-SqlUserAccess @PSBoundParameters
}
