function Sync-SqlDatabaseUser {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [PSCustomObject]$Login,
        [Parameter(Mandatory)] [string]$Database,
        [bool]$WhatIf = $false
    )

    $safeLogin  = $Login.login.Replace("'", "''")
    $existingUser = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
        -Query "SELECT name, default_schema_name FROM sys.database_principals WHERE name = '$safeLogin'" `
        -Database $Database

    # Optional default schema. Entra group users have none by default, so an unqualified
    # CREATE TABLE by a group member tries to create a schema named after that member and fails.
    $withSchema = if ($Login.defaultSchema) { " WITH DEFAULT_SCHEMA = [$($Login.defaultSchema.Replace(']', ']]'))]" } else { '' }

    if (-not $existingUser) {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would create $($Login.type) USER $($Login.login) in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $true
            return
        }
        Write-Host "Creating $($Login.type) USER $($Login.login) in $Database..." -ForegroundColor Cyan
        switch ($Login.type) {
            'external' {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database -Query "CREATE USER [$($Login.login)] FROM EXTERNAL PROVIDER$withSchema;"
                Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $false
            }
            'sql' {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database -Query "CREATE USER [$($Login.login)] FOR LOGIN [$($Login.login)]$withSchema;"
                Add-SyncAction -Action 'CreateUser' -Login $Login.login -Database $Database -Detail $Login.type -Planned $false
            }
            default { Write-Host "Unknown user type for $($Login.login), skipping." -ForegroundColor Yellow; Add-SyncAction -Action 'UnknownUserType' -Login $Login.login -Database $Database -Severity Warning }
        }
        return
    }

    Write-Verbose "$($Login.type) USER $($Login.login) already exists in $Database."

    $currentSchema = [string]$existingUser.default_schema_name   # DBNull -> '' (DBNull is truthy)
    if ($Login.defaultSchema -and $currentSchema -ne $Login.defaultSchema) {
        $current = if ($currentSchema) { $currentSchema } else { 'none' }
        $detail  = "DEFAULT_SCHEMA = $($Login.defaultSchema) (was: $current)"
        if ($WhatIf) {
            Write-Host "[WhatIf] Would set default schema of USER $($Login.login) to [$($Login.defaultSchema)] in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'SetDefaultSchema' -Login $Login.login -Database $Database -Detail $detail -Planned $true
        } else {
            Write-Host "Setting default schema of USER $($Login.login) to [$($Login.defaultSchema)] in $Database..." -ForegroundColor Cyan
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                -Query "ALTER USER [$($Login.login)]$withSchema;"
            Add-SyncAction -Action 'SetDefaultSchema' -Login $Login.login -Database $Database -Detail $detail -Planned $false
        }
    }

    # Re-link SQL user to login in case the login was recreated
    if ($Login.type -eq 'sql' -and $Database -ne 'master') {
        Write-Verbose "Ensuring USER $($Login.login) is linked to LOGIN in $Database..."
        if (-not $WhatIf) {
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                -Query "ALTER USER [$($Login.login)] WITH LOGIN = [$($Login.login)];"
        }
    }
}
