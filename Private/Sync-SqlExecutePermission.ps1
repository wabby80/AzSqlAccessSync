function Sync-SqlExecutePermission {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$LoginName,
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string[]]$DesiredPermissions,
        [Parameter(Mandatory)] [hashtable]$Snapshot,
        [bool]$WhatIf = $false
    )

    $dbPermTable        = $Snapshot.ExecutePermsByDb[$Database]
    $currentPermissions = if ($dbPermTable) { $dbPermTable[$LoginName] } else { $null }
    if (-not $currentPermissions) { $currentPermissions = @() }

    foreach ($target in $DesiredPermissions) {
        if ($target -match '^SCHEMA::(.+)$') {
            $schemaName = $Matches[1]
            $label      = "EXECUTE ON SCHEMA::$schemaName"
            $grantSql   = "GRANT EXECUTE ON SCHEMA::[$schemaName] TO [$LoginName];"
        } else {
            $parts    = $target -split '\.', 2
            $label    = "EXECUTE ON $target"
            $grantSql = "GRANT EXECUTE ON [$($parts[0])].[$($parts[1])] TO [$LoginName];"
        }

        if ($target -in $currentPermissions) {
            Write-Verbose "$LoginName already has $label in $Database, skipping."
            continue
        }

        if ($WhatIf) {
            Write-Host "[WhatIf] Would grant $label to $LoginName in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'GrantExecute' -Login $LoginName -Database $Database -Detail $label -Planned $true
        } else {
            Write-Host "Granting $label to $LoginName in $Database" -ForegroundColor Cyan
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database -Query $grantSql
            Add-SyncAction -Action 'GrantExecute' -Login $LoginName -Database $Database -Detail $label -Planned $false
        }
    }
}
