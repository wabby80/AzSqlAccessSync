function Remove-SqlAccessDrift {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [PSCustomObject]$Login,
        [Parameter(Mandatory)] [string[]]$AllDatabasesOnServer,
        [Parameter(Mandatory)] [hashtable]$Snapshot,
        [bool]$WhatIf = $false
    )

    foreach ($dbName in $AllDatabasesOnServer) {
        if (-not $Snapshot.PrincipalsByDb[$dbName].ContainsKey($Login.login)) { continue }

        $dbDefinedInJson = $Login.databases | Where-Object { $_.database -eq $dbName }

        if (-not $dbDefinedInJson) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would remove user $($Login.login) from $dbName (not defined in JSON for this login)" -ForegroundColor Cyan
                Add-SyncAction -Action 'RemoveUser' -Login $Login.login -Database $dbName -Detail 'not defined in JSON for this login' -Planned $true
            } else {
                Write-Host "Removing user $($Login.login) from $dbName (not defined in JSON for this login)" -ForegroundColor Yellow
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
                    -Query "DROP USER [$($Login.login)];"
                Add-SyncAction -Action 'RemoveUser' -Login $Login.login -Database $dbName -Detail 'not defined in JSON for this login' -Planned $false
            }
            continue
        }

        # Remove roles not in JSON
        $jsonRoles    = @($dbDefinedInJson.roles)
        $currentRoles = $Snapshot.RolesByDb[$dbName][$Login.login]
        if (-not $currentRoles) { $currentRoles = @() }

        foreach ($role in ($currentRoles | Where-Object { $_ -notin $jsonRoles })) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would remove $($Login.login) from $role in $dbName (not in JSON)" -ForegroundColor Cyan
                Add-SyncAction -Action 'RemoveRole' -Login $Login.login -Database $dbName -Detail $role -Planned $true
            } else {
                Write-Host "Removing $($Login.login) from $role in $dbName (not in JSON)" -ForegroundColor Cyan
                if ($role.StartsWith('##')) {
                    Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
                        -Query "ALTER SERVER ROLE [$role] DROP MEMBER [$($Login.login)];"
                } else {
                    Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
                        -Query "ALTER ROLE [$role] DROP MEMBER [$($Login.login)];"
                }
                Add-SyncAction -Action 'RemoveRole' -Login $Login.login -Database $dbName -Detail $role -Planned $false
            }
        }

        # Remove VIEW permissions not in JSON
        $jsonViewPerms    = @($dbDefinedInJson.grantView)
        $currentViewPerms = $Snapshot.ViewPermsByDb[$dbName][$Login.login]
        if (-not $currentViewPerms) { $currentViewPerms = @() }

        foreach ($perm in ($currentViewPerms | Where-Object { $_ -notin $jsonViewPerms })) {
            if ($WhatIf) {
                Write-Host "[WhatIf] Would revoke VIEW $perm from $($Login.login) in $dbName (not in JSON)" -ForegroundColor Cyan
                Add-SyncAction -Action 'RevokeView' -Login $Login.login -Database $dbName -Detail $perm -Planned $true
            } else {
                Write-Host "Revoking VIEW $perm from $($Login.login) in $dbName (not in JSON)" -ForegroundColor Cyan
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
                    -Query "REVOKE VIEW $perm FROM [$($Login.login)];"
                Add-SyncAction -Action 'RevokeView' -Login $Login.login -Database $dbName -Detail $perm -Planned $false
            }
        }

        # Remove EXECUTE permissions not in JSON
        $jsonExecutePerms    = @($dbDefinedInJson.grantExecute)
        $currentExecutePerms = $Snapshot.ExecutePermsByDb[$dbName][$Login.login]
        if (-not $currentExecutePerms) { $currentExecutePerms = @() }

        foreach ($perm in ($currentExecutePerms | Where-Object { $_ -notin $jsonExecutePerms })) {
            if ($perm -match '^SCHEMA::(.+)$') {
                $revokeSql = "REVOKE EXECUTE ON SCHEMA::[$($Matches[1])] FROM [$($Login.login)];"
                $label     = "EXECUTE ON SCHEMA::$($Matches[1])"
            } else {
                $parts     = $perm -split '\.', 2
                $revokeSql = "REVOKE EXECUTE ON [$($parts[0])].[$($parts[1])] FROM [$($Login.login)];"
                $label     = "EXECUTE ON $perm"
            }
            if ($WhatIf) {
                Write-Host "[WhatIf] Would revoke $label from $($Login.login) in $dbName (not in JSON)" -ForegroundColor Cyan
                Add-SyncAction -Action 'RevokeExecute' -Login $Login.login -Database $dbName -Detail $label -Planned $true
            } else {
                Write-Host "Revoking $label from $($Login.login) in $dbName (not in JSON)" -ForegroundColor Cyan
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName -Query $revokeSql
                Add-SyncAction -Action 'RevokeExecute' -Login $Login.login -Database $dbName -Detail $label -Planned $false
            }
        }
    }

    # Remove server role memberships not in JSON (server-level — checked once per login, not per database)
    $allJsonServerRoles = $Login.databases | ForEach-Object { $_.roles } |
        Where-Object { $_ -and $_.StartsWith('##') } | Select-Object -Unique
    $currentServerRoles = $Snapshot.ServerRolesByLogin[$Login.login]
    if (-not $currentServerRoles) { $currentServerRoles = @() }

    foreach ($serverRole in ($currentServerRoles | Where-Object { $_ -notin $allJsonServerRoles })) {
        if ($WhatIf) {
            Write-Host "[WhatIf] Would remove $($Login.login) from server role $serverRole (not in JSON)" -ForegroundColor Cyan
            Add-SyncAction -Action 'RemoveServerRole' -Login $Login.login -Detail $serverRole -Planned $true
        } else {
            Write-Host "Removing $($Login.login) from server role $serverRole (not in JSON)" -ForegroundColor Cyan
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
                -Query "ALTER SERVER ROLE [$serverRole] DROP MEMBER [$($Login.login)];"
            Add-SyncAction -Action 'RemoveServerRole' -Login $Login.login -Detail $serverRole -Planned $false
        }
    }
}
