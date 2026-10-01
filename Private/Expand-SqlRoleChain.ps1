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

        One role name can have several definitions with different "databases" scopes (e.g. a
        master-only definition next to the default one), so only the definitions in scope for
        -Database are expanded, using the same rule as Sync-SqlRoles: no "databases" field means
        every database except master; otherwise only the databases listed.
    #>
    param(
        [Parameter(Mandatory)] [string]$RoleName,
        [Parameter(Mandatory)] [hashtable]$RoleDefsByName,
        [Parameter(Mandatory)] [string]$Database,
        [string[]]$ChainSoFar = @()
    )

    if ($RoleName -in $ChainSoFar) {
        Write-Warning "Circular role membership detected: $(($ChainSoFar + $RoleName) -join ' > '). Stopping expansion."
        return [PSCustomObject]@{
            RoleChain           = ($ChainSoFar -join ' > ')
            EffectivePermission = "$RoleName (circular - not expanded)"
        }
    }

    # Guarded rather than piped straight through: piping a $null lookup into Where-Object runs the
    # filter once with $_ = $null, which passes the "no databases scope" test outside master.
    $candidates = $RoleDefsByName[$RoleName]
    $roleDefs   = if ($candidates) {
        @($candidates | Where-Object {
            if ($Database -eq 'master') { $_.databases -and ($Database -in $_.databases) }
            else { -not $_.databases -or ($Database -in $_.databases) }
        })
    } else { @() }

    if ($roleDefs.Count -eq 0) {
        # No Roles/*.json definition for this name in this database - it's terminal: a fixed/built-in
        # database role, a server role (##...##), or a custom role with no matching definition for
        # this environment/database.
        return [PSCustomObject]@{
            RoleChain           = ($ChainSoFar -join ' > ')
            EffectivePermission = $RoleName
        }
    }

    $newChain = $ChainSoFar + $RoleName
    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($roleDef in $roleDefs) {
        foreach ($parentRole in $roleDef.memberOf) {
            $results.AddRange([PSCustomObject[]]@(Expand-SqlRoleChain -RoleName $parentRole -RoleDefsByName $RoleDefsByName -Database $Database -ChainSoFar $newChain))
        }

        if ($roleDef.grantExecute) {
            $results.Add([PSCustomObject]@{ RoleChain = ($newChain -join ' > '); EffectivePermission = 'EXECUTE' })
        }

        foreach ($grant in $roleDef.grants) {
            $results.Add([PSCustomObject]@{ RoleChain = ($newChain -join ' > '); EffectivePermission = $grant })
        }
    }

    return $results
}
