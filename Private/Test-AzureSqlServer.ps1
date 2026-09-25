function Test-AzureSqlServer {
    <#
    .SYNOPSIS
        Detects whether the target server is Azure SQL Database (PaaS, single/pooled) as opposed
        to Azure SQL Managed Instance, an IaaS VM, or on-prem SQL Server.

    .DESCRIPTION
        Azure SQL Database has no real 'msdb' reachable via AAD token auth, unlike Managed Instance
        and VM/on-prem SQL Server, which both have a normal msdb. Uses SERVERPROPERTY('EngineEdition')
        (5 = Azure SQL Database) rather than inferring from server name or JSON contents, since that's
        the Microsoft-documented, reliable way to distinguish PaaS Azure SQL Database from everything
        else that looks similar on the surface.
    #>
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken
    )

    $row = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
        -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition"

    return ($row.EngineEdition -eq 5)
}
