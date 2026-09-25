function Invoke-SqlAccessQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlServer,
        [Parameter(Mandatory)]
        [string]$AccessToken,
        [Parameter(Mandatory)]
        [string]$Query,
        [string]$Database = 'master'
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-Warning 'Query is empty. Skipping execution.'
        return $null
    }

    try {
        Write-Verbose "Executing query on $SqlServer, Database: $Database"
        $result = Invoke-Sqlcmd `
            -ServerInstance $SqlServer `
            -Database $Database `
            -AccessToken $AccessToken `
            -Query $Query `
            -QueryTimeout 30 `
            -ErrorAction Stop `
            -TrustServerCertificate `
            -OutputSqlErrors $true
        return $result
    } catch {
        Write-Warning "SQL query failed on ${SqlServer}/${Database}: $($_.Exception.Message)"
        Write-Verbose "Failed query: $Query"
        if (Get-Variable -Name SyncQueryErrors -Scope Script -ErrorAction SilentlyContinue) {
            $script:SyncQueryErrors.Add("[${SqlServer}/${Database}] $($_.Exception.Message)")
        }
        return $null
    }
}
