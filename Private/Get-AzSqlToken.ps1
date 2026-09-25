function Get-AzSqlToken {
    param(
        [string]$Resource = 'https://database.windows.net/',
        [switch]$Reconnect
    )

    Enable-AzContextAutosave -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null

    if ($Reconnect) {
        Write-Host 'Reconnect flag detected. Clearing Azure context and forcing re-authentication...' -ForegroundColor Yellow
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($context -and $context.Account) {
        try {
            $token = Resolve-AzToken -Resource $Resource
            if ($token) {
                Write-Verbose "Using existing Azure context for $($context.Account.Id)"
                return $token
            }
        } catch {
            Write-Verbose 'Existing context token expired or invalid, re-authenticating...'
        }
    }

    if ($env:CI) {
        throw 'No valid Azure context found. In CI/CD pipelines, authenticate before invoking this module (e.g. via the azure/login action).'
    }

    Write-Host 'Azure authentication required. Please sign in...' -ForegroundColor Yellow
    Connect-AzAccount -UseDeviceAuthentication | Out-Null

    $token = Resolve-AzToken -Resource $Resource
    if (-not $token) {
        throw 'Could not acquire Azure SQL access token after authentication.'
    }
    return $token
}

function Resolve-AzToken {
    param([string]$Resource)
    $raw = (Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop).Token
    if ($raw -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $raw).Password
    }
    return $raw
}
