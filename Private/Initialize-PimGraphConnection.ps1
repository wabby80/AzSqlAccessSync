function Initialize-PimGraphConnection {
    <#
    .SYNOPSIS
        Pre-flight check: ensures Microsoft.Graph.Authentication is installed and connected with the
        scope needed for PIM-for-Groups eligibility checks.

    .DESCRIPTION
        The existing Az PowerShell sign-in (Connect-AzAccount) cannot be used for this: whatever
        app Connect-AzAccount authenticates through has a fixed, Microsoft-registered permission set
        that does not include PrivilegedEligibilitySchedule.Read.AzureADGroup at all - no amount of
        directory-role privilege (Global Admin included) or consent changes that, since it's about
        what the *client application* is registered to request, not the signed-in user's role.
        Microsoft Graph PowerShell's own app ("Microsoft Graph Command Line Tools") is designed for
        incremental scope consent and does support it.

        Microsoft.Graph.Authentication is a soft dependency of this module - not in RequiredModules,
        installed and connected automatically only when a PIM eligibility check is actually
        attempted (see Get-EntraGroupPimEligibleMembers) - so nobody who never encounters a
        PIM-for-Groups-enabled group needs it, or the interactive consent prompt it triggers on
        first use.
    #>
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host 'Microsoft.Graph.Authentication module not found - installing (required for PIM eligibility checks)...' -ForegroundColor Yellow
        try {
            Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        } catch {
            throw "Could not install the Microsoft.Graph.Authentication module automatically: $($_.Exception.Message). Install it manually with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        }
    }

    if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    }

    $context = Get-MgContext
    if (-not $context -or 'PrivilegedEligibilitySchedule.Read.AzureADGroup' -notin $context.Scopes) {
        Write-Host 'Connecting to Microsoft Graph for PIM eligibility checks (one-time consent may be required)...' -ForegroundColor Yellow
        Connect-MgGraph -Scopes 'PrivilegedEligibilitySchedule.Read.AzureADGroup' -NoWelcome -ErrorAction Stop
    }
}
