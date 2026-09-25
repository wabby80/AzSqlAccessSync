function Sync-SqlDatabaseUser {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [PSCustomObject]$Login,
        [Parameter(Mandatory)] [string]$Database,
        [bool]$WhatIf = $false
    )

    $safeLogin  = $Login.login.Replace("'", "''")
    $userExists = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
        -Query "SELECT name FROM sys.database_principals WHERE name = '$safeLogin'" `
        -Database $Database | Select-Object -ExpandProperty name

    if (-not $userExists) {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would create $($Login.type) USER $($Login.login) in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $true
            return
        }
        Write-Host "Creating $($Login.type) USER $($Login.login) in $Database..." -ForegroundColor Cyan
        switch ($Login.type) {
            'external' {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database -Query "CREATE USER [$($Login.login)] FROM EXTERNAL PROVIDER;"
                Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $false
            }
            'sql' {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database -Query "CREATE USER [$($Login.login)] FOR LOGIN [$($Login.login)];"
                Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $false
            }
            default { Write-Host "Unknown user type for $($Login.login), skipping." -ForegroundColor Yellow; Add-SyncAction -Action 'UnknownUserType' -Login $Login.login -Database $Database -Severity Warning }
        }
        return
    }

    Write-Verbose "$($Login.type) USER $($Login.login) already exists in $Database."

    # Re-link SQL user to login in case the login was recreated
    if ($Login.type -eq 'sql' -and $Database -ne 'master') {
        Write-Verbose "Ensuring USER $($Login.login) is linked to LOGIN in $Database..."
        if (-not $WhatIf) {
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                -Query "ALTER USER [$($Login.login)] WITH LOGIN = [$($Login.login)];"
        }
    }
}
