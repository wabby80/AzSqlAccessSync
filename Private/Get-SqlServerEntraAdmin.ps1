function Get-SqlServerEntraAdmin {
    <#
    .SYNOPSIS
        Returns the Microsoft Entra admin configured on an Azure SQL logical server, if any.

    .DESCRIPTION
        The server-level Entra admin (Terraform azuread_administrator /
        azurerm_mssql_active_directory_administrator) grants that identity sysadmin-equivalent
        access to every database on the server - an ARM/control-plane property, not anything
        declared in Logins/*.json, so it's invisible to the rest of this report unless looked up
        separately here. This is an ARM call (Get-AzSqlServer, Get-AzSqlServerActiveDirectory
        Administrator), not a SQL connection - it doesn't need a SQL access token and doesn't
        violate this module's "never queries the target SQL server" design for this report.

        Matches by the server's short name (the FQDN's first label) against Get-AzSqlServer in
        whatever subscription is currently selected - Azure SQL server names are globally unique,
        so this is safe within the right subscription. Returns $null if the server isn't found
        there or has no Entra admin configured. Not finding it is silent for a VM-hosted target
        (no such ARM resource exists), but for an Azure SQL Database FQDN it warns, since it
        usually means the wrong subscription is selected and the report would otherwise look
        complete without the admin rows.
    #>
    param(
        [Parameter(Mandatory)] [string]$SqlServerFqdn
    )

    $shortName = ($SqlServerFqdn -split '\.')[0]
    $server    = Get-AzSqlServer -ErrorAction SilentlyContinue | Where-Object { $_.ServerName -eq $shortName } | Select-Object -First 1
    if (-not $server) {
        if ($SqlServerFqdn -match '\.database\.windows\.net$') {
            Write-Warning "Azure SQL server '$shortName' not found in the current Az subscription '$((Get-AzContext).Subscription.Name)' - the server Entra admin is missing from this report. Select the server's subscription with Set-AzContext and run it again."
        }
        return $null
    }

    return Get-AzSqlServerActiveDirectoryAdministrator -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
}
