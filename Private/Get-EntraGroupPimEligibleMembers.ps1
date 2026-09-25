function Get-EntraGroupPimEligibleMembers {
    <#
    .SYNOPSIS
        Returns the ObjectIds of principals PIM-eligible for member access to a group.

    .DESCRIPTION
        Get-AzADGroupMember only returns a group's currently-active members. A PIM-for-Groups
        eligible assignment that nobody has activated yet is invisible to it - which silently drops
        people who could elevate themselves into the group (and everything it grants) on demand
        from this report entirely, reporting the group as empty instead. This queries Microsoft
        Graph's PIM-for-Groups eligibility schedule directly (there's no Az.Resources cmdlet for
        it).

        Uses Microsoft.Graph.Authentication (see Initialize-PimGraphConnection), not the existing
        Az token - the app Connect-AzAccount signs into has a fixed permission set that does not
        include PrivilegedEligibilitySchedule.Read.AzureADGroup at all, regardless of the signed-in
        user's directory role, so no Az token can ever carry it.

        If the call still fails (e.g. consent declined, or the signed-in user genuinely lacks PIM
        read access), this reports it as a warning and treats the group as having no eligible
        members rather than failing the whole report.
    #>
    param(
        [Parameter(Mandatory)] [string]$GroupId,
        [Parameter(Mandatory)] [hashtable]$Cache
    )

    $cacheKey = "pim-eligible:$GroupId"
    if ($Cache.ContainsKey($cacheKey)) { return $Cache[$cacheKey] }

    $eligibleIds = @()
    try {
        Initialize-PimGraphConnection
        $uri      = "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?`$filter=groupId eq '$GroupId'"
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject -ErrorAction Stop
        $eligibleIds = @($response.value | Where-Object { $_.accessId -eq 'member' } | Select-Object -ExpandProperty principalId -Unique)
    } catch {
        Write-Warning "Could not check PIM eligibility for group '$GroupId' (treating as none): $($_.Exception.Message)"
    }

    $Cache[$cacheKey] = $eligibleIds
    return $eligibleIds
}
