function Expand-ResolvedEntraObject {
    <#
    .SYNOPSIS
        Recursively walks an already-resolved Entra object down to its leaf principals.

    .DESCRIPTION
        Internal recursive core for Expand-EntraPrincipalChain - kept as its own function (one
        function per file, matching this module's convention) rather than nested inline, since it
        recurses on the already-resolved object (looked up once via Resolve-EntraObject and cached
        by ObjectId) rather than re-resolving each nested member by name.

        Every leaf carries a MembershipState: 'Active' if every hop from the top-level login down
        to that leaf is a real, currently-active membership, or 'Eligible' if any hop along the way
        is only a PIM-for-Groups eligible assignment nobody has activated - meaning the leaf doesn't
        actually have this access right now, but could get it on demand. IsEligible tracks whether
        the current path has already crossed such a hop; once true, it stays true for every
        descendant, since access below an unactivated gate isn't real either.
    #>
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Obj,
        [Parameter(Mandatory)] [hashtable]$Cache,
        [string[]]$ChainSoFar = @(),
        [string[]]$VisitedIds = @(),
        [bool]$IsEligible = $false
    )

    $membershipState = if ($IsEligible) { 'Eligible' } else { 'Active' }

    if ($Obj.Type -ne 'Group') {
        return [PSCustomObject]@{
            GroupChain            = ($ChainSoFar -join ' > ')
            ResolvedPrincipal     = $Obj.DisplayName
            ResolvedPrincipalType = $Obj.Type
            MembershipState       = $membershipState
        }
    }

    if ($Obj.Id -and ($Obj.Id -in $VisitedIds)) {
        Write-Warning "Circular group membership detected at '$($Obj.DisplayName)' (chain: $(($ChainSoFar + $Obj.DisplayName) -join ' > ')). Stopping expansion."
        return [PSCustomObject]@{
            GroupChain            = ($ChainSoFar -join ' > ')
            ResolvedPrincipal     = $Obj.DisplayName
            ResolvedPrincipalType = 'Group (circular - not expanded)'
            MembershipState       = $membershipState
        }
    }

    $newChain   = $ChainSoFar + $Obj.DisplayName
    $newVisited = $VisitedIds + $Obj.Id
    $results    = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($memberId in $Obj.Members) {
        $memberObj = Resolve-EntraObject -ObjectId $memberId -Cache $Cache
        $results.AddRange([PSCustomObject[]]@(Expand-ResolvedEntraObject -Obj $memberObj -Cache $Cache -ChainSoFar $newChain -VisitedIds $newVisited -IsEligible $IsEligible))
    }

    # PIM-for-Groups eligible members nobody has activated yet - invisible to Get-AzADGroupMember,
    # so without this branch an eligible-but-unactivated group reports as empty even though its
    # members could elevate themselves into real access at any time (see Get-EntraGroupPimEligibleMembers).
    foreach ($memberId in $Obj.EligibleMembers) {
        $memberObj = Resolve-EntraObject -ObjectId $memberId -Cache $Cache
        $results.AddRange([PSCustomObject[]]@(Expand-ResolvedEntraObject -Obj $memberObj -Cache $Cache -ChainSoFar $newChain -VisitedIds $newVisited -IsEligible $true))
    }

    if ($results.Count -eq 0) {
        $results.Add([PSCustomObject]@{
            GroupChain            = ($newChain -join ' > ')
            ResolvedPrincipal     = '(empty group)'
            ResolvedPrincipalType = 'None'
            MembershipState       = $membershipState
        })
    }

    return $results
}
