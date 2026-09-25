function Remove-SqlOrphanedLogin {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string[]]$LoginNames,
        [bool]$WhatIf = $false
    )

    foreach ($loginName in $LoginNames) {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would drop LOGIN $loginName (not in JSON, no database user or server-level access)" -ForegroundColor Cyan
            Add-SyncAction -Action 'RemoveLogin' -Login $loginName -Detail 'not in JSON, no database user or server-level access' -Planned $true
        } else {
            Write-Host "Dropping LOGIN $loginName (not in JSON, no database user or server-level access)" -ForegroundColor Yellow
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query "DROP LOGIN [$loginName];"
            Add-SyncAction -Action 'RemoveLogin' -Login $loginName -Detail 'not in JSON, no database user or server-level access' -Planned $false
        }
    }
}
