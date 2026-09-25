# Script-level params: no Mandatory/ParameterSet attributes so dot-sourcing during Import-Module
# does not prompt or throw. Validation happens inside the function's own param block.
param(
    [string]$LoginsFolderPath,
    [string]$RolesFolderPath,
    [string]$Environment,
    [string]$SqlServer,
    [string]$EnvProfile,
    [Alias('Database')] [string]$OneDatabase,
    [switch]$ExportToExcel,
    [string]$ExportPath,
    [switch]$PassThru
)

function Get-SqlAccessReport {
    <#
    .SYNOPSIS
        Reports who actually has access to a database, resolved all the way down to real principals.

    .DESCRIPTION
        Reads the declared access from Logins/*.json and Roles/*.json for the given environment -
        the same source of truth Sync-SqlUserAccess enforces onto SQL - and fully resolves it:

        - A role assigned to a login (built-in or a custom role from Roles/*.json) is expanded down
          through any nested role membership to its terminal, effective grants (see
          Expand-SqlRoleChain), while still recording the role name(s) that led there.
        - An `external` login is resolved through Entra ID (see Expand-EntraPrincipalChain): if it's
          a security group, membership is walked recursively - including nested groups - down to the
          actual Users, Managed Identities, and Service Principals inside it. A `sql` login is
          already a leaf and skips Entra resolution entirely.
        - A PIM-for-Groups eligible assignment nobody has activated yet is invisible to a plain
          group-membership lookup, which would otherwise silently report that branch as empty even
          though those people could self-elevate into real access at any time. This is checked
          separately (see Get-EntraGroupPimEligibleMembers) and surfaced via MembershipState -
          'Active' for a real current member, 'Eligible' for someone who could activate into the
          access but hasn't. Once any hop in a chain is Eligible, every leaf below it is too, since
          access below an unactivated gate isn't real either.
        - The server's Microsoft Entra admin (see Get-SqlServerEntraAdmin) - an ARM-level property
          (Terraform azuread_administrator), not anything declared in JSON - has sysadmin-equivalent
          access to every database on the server. It's looked up via Get-AzSqlServer/
          Get-AzSqlServerActiveDirectoryAdministrator (an ARM call, not a SQL connection) and
          resolved/expanded the same way as any other Entra login or group. These rows always come
          first in the output and cover every database the report already covers, regardless of
          -Database, since that access applies no matter which database is being looked at.

        This never queries the target SQL server itself - it reports the declared/enforced state
        from JSON plus the server's ARM-level Entra admin setting, not a live snapshot of SQL. If
        Sync-SqlUserAccess hasn't been run recently for this environment, this report may not
        reflect what's actually in SQL right now; run `Sync-SqlUserAccess -Verify` first if that's
        in doubt.

        Output is one row per (database, permission, resolved leaf principal), so the same person
        appears once per database they can reach through any path.

    .PARAMETER LoginsFolderPath
        Path to the folder containing per-login JSON files.

    .PARAMETER RolesFolderPath
        Optional. Path to the folder containing role definition JSON files (the same folder
        Sync-SqlRoles uses). Without it, custom roles are reported as-is instead of being expanded
        into their effective grants. With -EnvProfile, read from the profile's RolesFolderPath.

    .PARAMETER Environment
        The environment to match against "acceptedenvironments" in each JSON file (e.g. 'DEV', 'PROD').

    .PARAMETER SqlServer
        The Azure SQL Server FQDN, used only to look up the server's Microsoft Entra admin via ARM
        (Get-AzSqlServer/Get-AzSqlServerActiveDirectoryAdministrator) - this report never connects
        to SQL itself. Matched by short server name against whatever Azure subscription is
        currently selected; silently skipped (no admin rows, no error) if not found there, which is
        the expected/correct outcome for a VM-hosted target (no such ARM concept exists for those).

    .PARAMETER EnvProfile
        Path to a JSON profile file containing LoginsFolderPath, SqlServer, Environment, and
        optional RolesFolderPath and LoginIgnoreList (same profile files Sync-SqlUserAccess uses).

    .PARAMETER OneDatabase
        Limits the report to a single database. Omit to report on every database declared in JSON.
        The server Entra admin's rows are still included for this one database, since that access
        isn't scoped by -Database at all.

    .PARAMETER ExportToExcel
        Writes the report to a formatted .xlsx (a title and generated-on date above the table, a
        light-blue-filled bold header row frozen while scrolling, autofilter) in addition to
        printing it to the console, then opens it. The ImportExcel module (not a hard dependency of
        this module - only needed when
        this switch is used) is installed automatically on first use if it isn't already present.

    .PARAMETER ExportPath
        Output path for -ExportToExcel. Defaults to
        <Desktop>\SQLAccessReport_<Environment>_(<Database>_)<yyyyMMdd>.xlsx - the Database segment
        only appears when -Database was specified.

    .PARAMETER PassThru
        Returns the flat report rows as objects, for further scripting/piping.

    .EXAMPLE
        Get-SqlAccessReport -EnvProfile .\Profiles\example.json

    .EXAMPLE
        Get-SqlAccessReport -EnvProfile .\Profiles\example.json -Database MyAppDb -ExportToExcel
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$LoginsFolderPath,

        [Parameter(ParameterSetName = 'Direct')]
        [string]$RolesFolderPath,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$Environment,

        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [string]$SqlServer,

        [Parameter(Mandatory, ParameterSetName = 'Profile')]
        [string]$EnvProfile,

        [Parameter(Mandatory = $false)]
        [Alias('Database')]
        [string]$OneDatabase,

        [switch]$ExportToExcel,
        [string]$ExportPath,
        [switch]$PassThru
    )

    # --- Startup banner ---
    Write-Host "Starting SQL Access Report`n" -ForegroundColor Green

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
        if ($ep.RolesFolderPath) {
            $RolesFolderPath = if ([System.IO.Path]::IsPathRooted($ep.RolesFolderPath)) {
                $ep.RolesFolderPath
            } else {
                Join-Path $profileDir $ep.RolesFolderPath
            }
        }
        $Environment = $ep.Environment
        $SqlServer   = $ep.SqlServer
        if ($ep.LoginIgnoreList) { $loginIgnoreList = $ep.LoginIgnoreList }
    } else {
        Write-Host "Logins Folder Path:        $LoginsFolderPath" -ForegroundColor Cyan
        Write-Host "SQL Server:                $SqlServer"        -ForegroundColor Cyan
        Write-Host "Environment:               $Environment"      -ForegroundColor Cyan
    }
    if ($RolesFolderPath) { Write-Host "Roles Folder Path:         $RolesFolderPath" -ForegroundColor Cyan }

    if ($OneDatabase) { Write-Host "Database (filtered):       $OneDatabase" -ForegroundColor Cyan }
    Write-Host ''

    # --- Pre-flight: fail fast if -ExportToExcel can't be satisfied, before doing any of the
    # role/Entra expansion work below. ---
    if ($ExportToExcel) { Initialize-ImportExcelModule }

    # --- Load declared access from JSON (no SQL connection - see .DESCRIPTION) ---
    $allLogins = Import-LoginConfig -LoginsFolderPath $LoginsFolderPath -Environment $Environment -IgnoreList $loginIgnoreList

    $roleDefsByName = @{}
    if ($RolesFolderPath) {
        foreach ($roleDef in (Import-RoleConfig -RolesFolderPath $RolesFolderPath -Environment $Environment)) {
            $roleDefsByName[$roleDef.role] = $roleDef
        }
    } else {
        Write-Warning 'No RolesFolderPath given - custom roles are reported as-is, not expanded into their effective grants.'
    }

    $entraCache = @{}
    $rows       = [System.Collections.Generic.List[PSCustomObject]]::new()
    $loginCount = @($allLogins).Count
    $loginIndex = 0

    foreach ($login in $allLogins) {
        $loginIndex++
        Write-Progress -Activity "Building SQL access report" -Status $login.login `
            -PercentComplete ([Math]::Round($loginIndex / $loginCount * 100))

        $dbsForLogin = if ($OneDatabase) {
            $login.databases | Where-Object { $_.database -eq $OneDatabase }
        } else {
            $login.databases
        }
        if (-not $dbsForLogin) { continue }

        # Resolved once per login, not once per database - the same login/group resolves to the
        # same leaf set everywhere it's granted access.
        $leaves = if ($login.type -eq 'external') {
            @(Expand-EntraPrincipalChain -PrincipalName $login.login -Cache $entraCache)
        } else {
            # SQL-authentication logins aren't PIM-gated - always a real, active login.
            @([PSCustomObject]@{ GroupChain = ''; ResolvedPrincipal = $login.login; ResolvedPrincipalType = 'SQL Login'; MembershipState = 'Active' })
        }

        foreach ($db in $dbsForLogin) {
            $permissionEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

            foreach ($roleName in $db.roles) {
                $permissionEntries.AddRange([PSCustomObject[]]@(Expand-SqlRoleChain -RoleName $roleName -RoleDefsByName $roleDefsByName))
            }
            foreach ($viewPerm in $db.grantView) {
                $permissionEntries.Add([PSCustomObject]@{ RoleChain = ''; EffectivePermission = "VIEW $viewPerm" })
            }
            foreach ($execPerm in $db.grantExecute) {
                $permissionEntries.Add([PSCustomObject]@{ RoleChain = ''; EffectivePermission = "EXECUTE $execPerm" })
            }

            foreach ($perm in $permissionEntries) {
                foreach ($leaf in $leaves) {
                    $rows.Add([PSCustomObject]@{
                        Database              = $db.database
                        GrantedToLogin        = $login.login
                        LoginType             = $login.type
                        RoleChain             = $perm.RoleChain
                        EffectivePermission   = $perm.EffectivePermission
                        GroupChain            = $leaf.GroupChain
                        ResolvedPrincipal     = $leaf.ResolvedPrincipal
                        ResolvedPrincipalType = $leaf.ResolvedPrincipalType
                        MembershipState       = $leaf.MembershipState
                    })
                }
            }
        }
    }

    Write-Progress -Activity "Building SQL access report" -Completed

    # --- Server Entra admin (see Get-SqlServerEntraAdmin) - sysadmin-equivalent on every database,
    # an ARM-level property rather than anything declared in JSON, so it's resolved separately and
    # placed first in the output. Covers every database the report already covers, regardless of
    # -Database, since this access isn't scoped by database at all. ---
    $adminRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($SqlServer) {
        $serverAdmin = Get-SqlServerEntraAdmin -SqlServerFqdn $SqlServer
        if ($serverAdmin) {
            $reportDatabases = if ($OneDatabase) {
                @($OneDatabase)
            } else {
                @($allLogins | ForEach-Object { $_.databases } | ForEach-Object { $_.database } | Select-Object -Unique)
            }

            $adminObj    = Resolve-EntraObject -ObjectId $serverAdmin.ObjectId -Cache $entraCache
            $adminLeaves = @(Expand-ResolvedEntraObject -Obj $adminObj -Cache $entraCache)

            foreach ($dbName in $reportDatabases) {
                foreach ($leaf in $adminLeaves) {
                    $adminRows.Add([PSCustomObject]@{
                        Database              = $dbName
                        GrantedToLogin        = $serverAdmin.DisplayName
                        LoginType             = 'entra-admin'
                        RoleChain             = ''
                        EffectivePermission   = 'Server Entra Admin (full access to every database)'
                        GroupChain            = $leaf.GroupChain
                        ResolvedPrincipal     = $leaf.ResolvedPrincipal
                        ResolvedPrincipalType = $leaf.ResolvedPrincipalType
                        MembershipState       = $leaf.MembershipState
                    })
                }
            }
        }
    }

    # Grouped by database first, so the default view answers "who's in this database" - re-sort/
    # filter in Excel (autofilter is on) to instead answer "how many databases does this person touch".
    # Server Entra admin rows always lead, ahead of the per-database grouping.
    $sortedRows = @($adminRows) + @($rows | Sort-Object Database, GrantedToLogin, ResolvedPrincipal)

    # --- Console output ---
    # Piped through Out-Host (not left to the success stream) so Format-Table's format objects never
    # leak into -PassThru's return value - Write-Host has this property automatically elsewhere in
    # this module, but Format-Table writes to the success stream unless explicitly redirected here.
    Write-Host "=== Access Report ($($sortedRows.Count) rows) ===" -ForegroundColor Cyan
    $sortedRows | Format-Table -AutoSize | Out-Host

    # --- Excel export --- (ImportExcel already installed/imported by the pre-flight check above)
    if ($ExportToExcel) {
        if (-not $ExportPath) {
            $dbSegment   = if ($OneDatabase) { "$($OneDatabase)_" } else { '' }
            $fileName    = "SQLAccessReport_$($Environment)_$($dbSegment)$(Get-Date -Format 'yyyyMMdd').xlsx"
            $ExportPath  = Join-Path ([Environment]::GetFolderPath('Desktop')) $fileName
        }

        # The default filename is date-based (no time component), so re-running the report later
        # the same day reuses the same path. Export-Excel doesn't clear a worksheet before writing -
        # it only overwrites the cells it explicitly writes - so without this, stale cells and
        # leftover conditional formatting/tables from an earlier run today would still be sitting
        # in the file underneath/around the new content. Deleting the file first guarantees every
        # run starts from a completely clean sheet.
        if (Test-Path $ExportPath) {
            try {
                Remove-Item $ExportPath -Force -ErrorAction Stop
            } catch {
                throw "Could not replace existing file '$ExportPath' - is it still open in Excel (this command opens it automatically)? Close it and try again. $($_.Exception.Message)"
            }
        }

        # Table starts a few rows down (row 4) to leave room for a title (row 1) and a generated-on
        # date (row 2), with a blank row (3) between the date and the header.
        $titleRow  = 1
        $dateRow   = 2
        $headerRow = 4

        $excelPackage = $sortedRows | Export-Excel -Path $ExportPath -WorksheetName 'AccessReport' `
            -AutoSize -BoldTopRow -AutoFilter -StartRow $headerRow -PassThru

        $worksheet  = $excelPackage.Workbook.Worksheets['AccessReport']
        $lastColumn = $worksheet.Dimension.End.Column

        $worksheet.Cells[$titleRow, 1].Value      = 'SQL Access Report'
        $worksheet.Cells[$titleRow, 1].Style.Font.Bold = $true
        $worksheet.Cells[$titleRow, 1].Style.Font.Size = 14

        $worksheet.Cells[$dateRow, 1].Value = "Generated: $(Get-Date -Format 'yyyy-MM-dd HH\:mm')"

        $headerRange = $worksheet.Cells[$headerRow, 1, $headerRow, $lastColumn]
        $headerRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $headerRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(0xDA, 0xE8, 0xFC))

        # -FreezeTopRow always freezes literal row 1, which is the title here, not the header - so
        # the freeze pane is set explicitly to keep rows 1..headerRow visible while scrolling data.
        $worksheet.View.FreezePanes($headerRow + 1, 1)

        Close-ExcelPackage $excelPackage

        Write-Host "`nExported to $ExportPath" -ForegroundColor Cyan

        if (-not $env:CI) {
            Start-Process -FilePath $ExportPath
        }
    }

    if ($PassThru) { return $sortedRows }
}

# Self-invoke when executed directly as a script (not dot-sourced by the module).
# Loads private functions first since the module context is not available in standalone mode.
if ($MyInvocation.InvocationName -ne '.') {
    Get-ChildItem -Path "$PSScriptRoot\..\Private\*.ps1" | ForEach-Object { . $_.FullName }
    Get-SqlAccessReport @PSBoundParameters
}
