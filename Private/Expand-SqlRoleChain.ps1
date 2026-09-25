function Expand-SqlRoleChain {
    <#
    .SYNOPSIS
        Recursively expands a role name declared on a login into its terminal (effective) grants.

    .DESCRIPTION
        A role name assigned to a login in Logins/*.json is either a built-in/server role (already
        terminal - e.g. db_owner, ##MS_ServerStateReader##) or a custom role defined in Roles/*.json,
        which can itself be a member of further roles (memberOf), including other custom roles.
        This walks that chain until every branch bottoms out at something with no further
        definition, returning one result per terminal grant with the full role path that led to it.
    #>
    param(
        [Parameter(Mandatory)] [string]$RoleName,
        [Parameter(Mandatory)] [hashtable]$RoleDefsByName,
        [string[]]$ChainSoFar = @()
    )

    if ($RoleName -in $ChainSoFar) {
        Write-Warning "Circular role membership detected: $(($ChainSoFar + $RoleName) -join ' > '). Stopping expansion."
        return [PSCustomObject]@{
            RoleChain           = ($ChainSoFar -join ' > ')
            EffectivePermission = "$RoleName (circular - not expanded)"
        }
    }

    $roleDef = $RoleDefsByName[$RoleName]

    if (-not $roleDef) {
        # No Roles/*.json definition for this name - it's terminal: a fixed/built-in database role,
        # a server role (##...##), or a custom role with no matching definition for this environment.
        return [PSCustomObject]@{
            RoleChain           = ($ChainSoFar -join ' > ')
            EffectivePermission = $RoleName
        }
    }

    $newChain = $ChainSoFar + $RoleName
    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($parentRole in $roleDef.memberOf) {
        $results.AddRange([PSCustomObject[]]@(Expand-SqlRoleChain -RoleName $parentRole -RoleDefsByName $RoleDefsByName -ChainSoFar $newChain))
    }

    if ($roleDef.grantExecute) {
        $results.Add([PSCustomObject]@{ RoleChain = ($newChain -join ' > '); EffectivePermission = 'EXECUTE' })
    }

    foreach ($grant in $roleDef.grants) {
        $results.Add([PSCustomObject]@{ RoleChain = ($newChain -join ' > '); EffectivePermission = $grant })
    }

    return $results
}
