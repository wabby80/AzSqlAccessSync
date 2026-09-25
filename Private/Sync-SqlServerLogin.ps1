function Sync-SqlServerLogin {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [PSCustomObject]$Login,
        [bool]$WhatIf = $false
    )

    $safeLogin = $Login.login.Replace("'", "''")
    $loginExists = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        WITH tmp_logins AS (
            SELECT sl.name collate catalog_default AS name FROM sys.sql_logins AS sl
            UNION
            SELECT sp.name collate catalog_default AS name FROM sys.server_principals AS sp
            WHERE (type = 'X' OR type = 'E') AND principal_id >= 256
        )
        SELECT name FROM tmp_logins WHERE name = '$safeLogin'
"@ | Select-Object -ExpandProperty name

    if ($loginExists) {
        Write-Verbose "$($Login.type) LOGIN $($Login.login) already exists, checking databases for user access..."
        return $true
    }

    if (-not (Test-EntraIdPrincipal -PrincipalName $Login.login)) {
        Write-Host "ERROR: Entra ID principal '$($Login.login)' does not exist. Cannot create LOGIN." -ForegroundColor Red
        Add-SyncAction -Action 'EntraPrincipalMissing' -Login $Login.login -Severity Warning
        return $false
    }

    if ($WhatIf) {
        Write-Host "[WhatIf] Would create $($Login.type) LOGIN $($Login.login)" -ForegroundColor Cyan
        Add-SyncAction -Action 'CreateLogin' -Login $Login.login -Detail $Login.type -Planned $true
        return $true
    }

    switch ($Login.type) {
        'external' {
            Write-Host "Creating $($Login.type) LOGIN $($Login.login)" -ForegroundColor Cyan
            Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
                -Query "CREATE LOGIN [$($Login.login)] FROM EXTERNAL PROVIDER;"
            Add-SyncAction -Action 'CreateLogin' -Login $Login.login -Detail $Login.type -Planned $false
            return $true
        }
        'sql' {
            Write-Host "Skipping SQL login creation for $($Login.login) (manual intervention required - passwords must not be stored in JSON)." -ForegroundColor Yellow
            Add-SyncAction -Action 'SqlLoginSkipped' -Login $Login.login -Severity Warning
            return $false
        }
        default {
            Write-Host "Unknown login type '$($Login.type)' for $($Login.login), skipping." -ForegroundColor Yellow
            return $false
        }
    }
}
