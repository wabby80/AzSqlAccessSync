function Resolve-EntraObject {
    <#
    .SYNOPSIS
        Looks up and classifies a single Entra ID object, caching the result.

    .DESCRIPTION
        Classifies an object as Group, User, Managed Identity, or Service Principal, using the same
        try-in-order pattern as Test-EntraIdPrincipal (User, then Service Principal, then Group).
        Looks up by display name/UPN for a top-level login name, or by ObjectId when resolving a
        group member found during recursion. Results are cached in the caller-supplied hashtable by
        ObjectId (and, for a name-based lookup, by name too) so the same object is never looked up
        twice in one run - important once the same group/user shows up under several logins or
        several nested groups.

        A Group result also carries EligibleMembers - PIM-for-Groups eligible member assignments
        nobody has activated yet, via Get-EntraGroupPimEligibleMembers - separately from Members
        (currently-active membership, via Get-AzADGroupMember), so a caller can tell "has access
        right now" apart from "could elevate into having access".
    #>
    param(
        [string]$Name,
        [string]$ObjectId,
        [Parameter(Mandatory)] [hashtable]$Cache
    )

    $cacheKey = if ($ObjectId) { $ObjectId } else { "name:$Name" }
    if ($Cache.ContainsKey($cacheKey)) { return $Cache[$cacheKey] }

    $result = $null

    if ($ObjectId) {
        $user = Get-AzADUser -ObjectId $ObjectId -ErrorAction SilentlyContinue
        if ($user) {
            $result = [PSCustomObject]@{ Type = 'User'; Id = $ObjectId; DisplayName = $user.UserPrincipalName; Members = $null; EligibleMembers = $null }
        } else {
            $sp = Get-AzADServicePrincipal -ObjectId $ObjectId -ErrorAction SilentlyContinue
            if ($sp) {
                $type   = if ($sp.ServicePrincipalType -eq 'ManagedIdentity') { 'Managed Identity' } else { 'Service Principal' }
                $result = [PSCustomObject]@{ Type = $type; Id = $ObjectId; DisplayName = $sp.DisplayName; Members = $null; EligibleMembers = $null }
            } else {
                $grp = Get-AzADGroup -ObjectId $ObjectId -ErrorAction SilentlyContinue
                if ($grp) {
                    $memberIds   = @(Get-AzADGroupMember -GroupObjectId $ObjectId -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
                    $eligibleIds = @(Get-EntraGroupPimEligibleMembers -GroupId $ObjectId -Cache $Cache | Where-Object { $_ -notin $memberIds })
                    $result      = [PSCustomObject]@{ Type = 'Group'; Id = $ObjectId; DisplayName = $grp.DisplayName; Members = $memberIds; EligibleMembers = $eligibleIds }
                }
            }
        }
    } else {
        $odataFilter = "displayName eq '$($Name.Replace("'", "''"))'"

        $user = Get-AzADUser -UserPrincipalName $Name -ErrorAction SilentlyContinue
        if (-not $user) { $user = Get-AzADUser -Filter $odataFilter -ErrorAction SilentlyContinue }
        if ($user) {
            $result = [PSCustomObject]@{ Type = 'User'; Id = $user.Id; DisplayName = $user.UserPrincipalName; Members = $null; EligibleMembers = $null }
        } else {
            $sp = Get-AzADServicePrincipal -Filter $odataFilter -ErrorAction SilentlyContinue
            if ($sp) {
                $type   = if ($sp.ServicePrincipalType -eq 'ManagedIdentity') { 'Managed Identity' } else { 'Service Principal' }
                $result = [PSCustomObject]@{ Type = $type; Id = $sp.Id; DisplayName = $sp.DisplayName; Members = $null; EligibleMembers = $null }
            } else {
                $grp = Get-AzADGroup -Filter $odataFilter -ErrorAction SilentlyContinue
                if ($grp) {
                    $memberIds   = @(Get-AzADGroupMember -GroupObjectId $grp.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
                    $eligibleIds = @(Get-EntraGroupPimEligibleMembers -GroupId $grp.Id -Cache $Cache | Where-Object { $_ -notin $memberIds })
                    $result      = [PSCustomObject]@{ Type = 'Group'; Id = $grp.Id; DisplayName = $grp.DisplayName; Members = $memberIds; EligibleMembers = $eligibleIds }
                }
            }
        }
    }

    if (-not $result) {
        $result = [PSCustomObject]@{ Type = 'Not Found in Entra'; Id = $ObjectId; DisplayName = $Name; Members = $null; EligibleMembers = $null }
    }

    $Cache[$cacheKey] = $result
    if ($result.Id) { $Cache[$result.Id] = $result }
    return $result
}
