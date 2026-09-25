function Add-SyncAction {
    param(
        [Parameter(Mandatory)] [string]$Action,
        [string]$Login,
        [string]$Database,
        [string]$Detail,
        [bool]$Planned = $false,
        [ValidateSet('Change', 'Warning')] [string]$Severity = 'Change'
    )

    if (Get-Variable -Name SyncActions -Scope Script -ErrorAction SilentlyContinue) {
        $script:SyncActions.Add([PSCustomObject]@{
            Action   = $Action
            Severity = $Severity
            Login    = $Login
            Database = $Database
            Detail   = $Detail
            Planned  = $Planned
        })
    }
}
