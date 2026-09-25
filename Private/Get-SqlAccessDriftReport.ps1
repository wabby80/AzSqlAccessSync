function Get-SqlAccessDriftReport {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [PSCustomObject[]]$AllLogins,
        [Parameter(Mandatory)] [string[]]$AllDatabasesOnServer,
        [string[]]$IgnoreList = @(),
        [bool]$IsAzureSqlServer = $false
    )

    $allDbNames = $AllLogins | ForEach-Object { $_.databases } | ForEach-Object { $_.database } |
        Where-Object { $_ -ne 'master' -and $_ -in $AllDatabasesOnServer } | Select-Object -Unique

    # Build expected users per database
    $expectedUsersPerDb = @{}
    foreach ($dbName in $allDbNames) {
        $expectedUsersPerDb[$dbName] = $AllLogins |
            Where-Object { $_.databases | Where-Object { $_.database -eq $dbName } } |
            Select-Object -ExpandProperty login
    }

    # Extra users in each DB
    $extraUsers = @{}
    foreach ($dbName in $allDbNames) {
        $dbUsers = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
            -Query "SELECT name FROM sys.database_principals WHERE type IN ('E','S','X') AND name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys') AND name NOT LIKE '##%'" |
            Select-Object -ExpandProperty name
        $extra = $dbUsers | Where-Object { $_ -notin $expectedUsersPerDb[$dbName] }
        if ($extra) { $extraUsers[$dbName] = $extra }
    }

    # Logins not in JSON
    $allServerLogins = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        WITH tmp_logins AS (
            SELECT sl.name collate catalog_default AS name FROM sys.sql_logins AS sl
            UNION
            SELECT sp.name collate catalog_default AS name FROM sys.server_principals AS sp
            WHERE (type = 'X' OR type = 'E') AND principal_id >= 256
        )
        SELECT name FROM tmp_logins
"@ | Select-Object -ExpandProperty name

    $jsonLoginNames  = $AllLogins | Select-Object -ExpandProperty login
    $loginsNotInJson = $allServerLogins | Where-Object { $_ -notin $jsonLoginNames -and $_ -notin $IgnoreList }

    # Logins with no access anywhere - no database user AND no server-level access. This list also
    # decides what -RemoveLogin may drop, so it errs toward keeping a login: a login is only listed
    # when none of the following hold.
    #   - System login: sa (principal_id 1), ##...## certificate logins, principal_id < 256.
    #   - A user in any database on the server - every database, not just those named in JSON,
    #     plus master (and msdb on non-Azure-SQL-Database targets) - matched by name or SID.
    #   - A member of any server role (e.g. sysadmin - needs no database mapping).
    #   - Holds any server permission other than the default GRANT CONNECT SQL.
    #   - Owns a database (maps as dbo, not by name), or - non-Azure only - owns a SQL Agent job.
    # sys.sql_logins is joined alongside sys.server_principals for the same Azure SQL Database
    # reason as in Get-SqlAccessSnapshot: SQL-auth logins there only appear in sys.sql_logins.
    $loginRows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        SELECT sl.name collate catalog_default AS name, CONVERT(varchar(200), sl.sid, 1) AS sid
        FROM sys.sql_logins AS sl
        WHERE sl.principal_id >= 256 AND sl.name NOT LIKE '##%'
        UNION
        SELECT sp.name collate catalog_default AS name, CONVERT(varchar(200), sp.sid, 1) AS sid
        FROM sys.server_principals AS sp
        WHERE sp.type IN ('X','E') AND sp.principal_id >= 256 AND sp.name NOT LIKE '##%'
"@

    $mappingDatabases = @($AllDatabasesOnServer) + $(if ($IsAzureSqlServer) { @('master') } else { @('master', 'msdb') }) |
        Select-Object -Unique
    $mappedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $mappedSids  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($dbName in $mappingDatabases) {
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
            -Query "SELECT name, CONVERT(varchar(200), sid, 1) AS sid FROM sys.database_principals WHERE type IN ('E','S','X','U','G')"
        foreach ($row in $rows) {
            [void]$mappedNames.Add($row.name)
            if ($row.sid -isnot [System.DBNull]) { [void]$mappedSids.Add($row.sid) }
        }
    }

    $serverAccessNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        SELECT COALESCE(sp.name, sl.name) AS name
        FROM sys.server_role_members srm
        LEFT JOIN sys.server_principals sp ON sp.principal_id = srm.member_principal_id
        LEFT JOIN sys.sql_logins        sl ON sl.principal_id = srm.member_principal_id
        UNION
        SELECT COALESCE(sp.name, sl.name) AS name
        FROM sys.server_permissions p
        LEFT JOIN sys.server_principals sp ON sp.principal_id = p.grantee_principal_id
        LEFT JOIN sys.sql_logins        sl ON sl.principal_id = p.grantee_principal_id
        WHERE NOT (p.permission_name = 'CONNECT SQL' AND p.state IN ('G','W'))
"@
    foreach ($row in $rows) { if ($row.name -isnot [System.DBNull]) { [void]$serverAccessNames.Add($row.name) } }

    $ownerSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
        -Query "SELECT CONVERT(varchar(200), owner_sid, 1) AS sid FROM sys.databases"
    foreach ($row in $rows) { [void]$ownerSids.Add($row.sid) }
    if (-not $IsAzureSqlServer) {
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database 'msdb' `
            -Query "SELECT CONVERT(varchar(200), owner_sid, 1) AS sid FROM dbo.sysjobs"
        foreach ($row in $rows) { [void]$ownerSids.Add($row.sid) }
    }

    $loginsWithNoDb = @($loginRows | Where-Object {
            $_ -and
            $_.name -notin $IgnoreList -and
            -not $mappedNames.Contains($_.name) -and
            -not $mappedSids.Contains($_.sid) -and
            -not $serverAccessNames.Contains($_.name) -and
            -not $ownerSids.Contains($_.sid)
        } | Select-Object -ExpandProperty name)

    if ($extraUsers.Count -gt 0) {
        Write-Host "`nUsers not in JSON but present in DBs:" -ForegroundColor Yellow
        foreach ($db in $extraUsers.Keys) {
            Write-Host "$db : $($extraUsers[$db] -join ', ')"
        }
    }
    if ($loginsNotInJson.Count -gt 0) {
        Write-Host "`nLogins present in SQL but not defined in JSON:" -ForegroundColor Yellow
        Write-Host ($loginsNotInJson -join ', ')
    }
    if ($loginsWithNoDb.Count -gt 0) {
        Write-Host "`nLogins present in SQL with no database user and no server-level access:" -ForegroundColor Yellow
        Write-Host ($loginsWithNoDb -join ', ')
    }

    [PSCustomObject]@{
        HasDrift        = ($extraUsers.Count -gt 0 -or $loginsNotInJson.Count -gt 0 -or $loginsWithNoDb.Count -gt 0)
        ExtraUsers      = $extraUsers
        LoginsNotInJson = @($loginsNotInJson)
        LoginsWithNoDb  = @($loginsWithNoDb)
        AllServerLogins = @($allServerLogins)
    }
}
