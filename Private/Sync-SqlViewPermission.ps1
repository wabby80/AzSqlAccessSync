function Sync-SqlViewPermission {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$LoginName,
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string[]]$DesiredPermissions,
        [Parameter(Mandatory)] [hashtable]$Snapshot,
        [bool]$WhatIf = $false
    )

    $dbPermTable        = $Snapshot.ViewPermsByDb[$Database]
    $currentPermissions = if ($dbPermTable) { $dbPermTable[$LoginName] } else { $null }
    if (-not $currentPermissions) { $currentPermissions = @() }

    foreach ($viewPerm in $DesiredPermissions) {
        if ($viewPerm -in $currentPermissions) {
            Write-Verbose "$LoginName already has VIEW $viewPerm in $Database, skipping."
            continue
        }

        if ($WhatIf) {
            Write-Host "[WhatIf] Would grant VIEW $viewPerm to $LoginName in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'GrantView' -Login $LoginName -Database $Database -Detail $viewPerm -Planned $true
        } else {
            Write-Host "Granting VIEW $viewPerm to $LoginName in $Database" -ForegroundColor Cyan
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                -Query "GRANT VIEW $viewPerm TO [$LoginName];"
            Add-SyncAction -Action 'GrantView' -Login $LoginName -Database $Database -Detail $viewPerm -Planned $false
        }
    }
}
