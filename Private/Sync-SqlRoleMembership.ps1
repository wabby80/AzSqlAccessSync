function Sync-SqlRoleMembership {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$LoginName,
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string[]]$DesiredRoles,
        [Parameter(Mandatory)] [hashtable]$Snapshot,
        [bool]$WhatIf = $false
    )

    $dbRoleTable    = $Snapshot.RolesByDb[$Database]
    $currentDbRoles = if ($dbRoleTable) { $dbRoleTable[$LoginName] } else { $null }
    if (-not $currentDbRoles) { $currentDbRoles = @() }

    $currentServerRoles = $Snapshot.ServerRolesByLogin[$LoginName]
    if (-not $currentServerRoles) { $currentServerRoles = @() }

    foreach ($role in $DesiredRoles) {
        $isServerRole = $role.StartsWith('##')
        $knownRoles   = if ($isServerRole) { $Snapshot.KnownServerRoles } else { $Snapshot.KnownRolesByDb[$Database] }

        if (-not $knownRoles -or -not $knownRoles.ContainsKey($role)) {
            Write-Verbose "Role $role does not exist in $Database, skipping."
            continue
        }

        $currentRoles = if ($isServerRole) { $currentServerRoles } else { $currentDbRoles }
        if ($role -in $currentRoles) {
            Write-Verbose "$LoginName is already a member of $role in $Database, skipping."
            continue
        }

        if ($WhatIf) {
            Write-Host "[WhatIf] Would add $LoginName to $role in $Database" -ForegroundColor Cyan
            Add-SyncAction -Action 'AddRole' -Login $LoginName -Database $Database -Detail $role -Planned $true
        } else {
            Write-Host "Adding $LoginName to $role in $Database" -ForegroundColor Cyan
            if ($isServerRole) {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                    -Query "ALTER SERVER ROLE [$role] ADD MEMBER [$LoginName];"
            } else {
                Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $Database `
                    -Query "ALTER ROLE [$role] ADD MEMBER [$LoginName];"
            }
            Add-SyncAction -Action 'AddRole' -Login $LoginName -Database $Database -Detail $role -Planned $false
        }
    }
}
