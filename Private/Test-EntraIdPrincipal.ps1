function Test-EntraIdPrincipal {
    param(
        [Parameter(Mandatory)]
        [string]$PrincipalName
    )

    $odataFilter = "displayName eq '$($PrincipalName.Replace("'", "''"))'"
    $lookupErrors = @()

    if (Get-AzADUser             -UserPrincipalName $PrincipalName -ErrorAction SilentlyContinue -ErrorVariable +lookupErrors) { return $true }
    if (Get-AzADServicePrincipal -Filter $odataFilter              -ErrorAction SilentlyContinue -ErrorVariable +lookupErrors) { return $true }
    if (Get-AzADGroup            -Filter $odataFilter              -ErrorAction SilentlyContinue -ErrorVariable +lookupErrors) { return $true }

    if ($lookupErrors) {
        Write-Warning "Entra ID lookup for '$PrincipalName' failed with errors (treating as not found): $($lookupErrors -join '; ')"
    }

    return $false
}
