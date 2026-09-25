function Get-SqlAccessSnapshot {
    param(
        [Parameter(Mandatory)] [string]$SqlServer,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string[]]$AllDatabasesOnServer
    )

    # Single upfront read of current SQL state, reused by both the grant side (Sync-SqlRoleMembership,
    # Sync-SqlViewPermission, Sync-SqlExecutePermission) and the removal side (Remove-SqlAccessDrift),
    # instead of each login/role/permission issuing its own query.
    $snapshot = @{
        PrincipalsByDb     = @{}
        RolesByDb          = @{}
        ViewPermsByDb      = @{}
        ExecutePermsByDb   = @{}
        KnownRolesByDb     = @{}
        ServerRolesByLogin = @{}
        KnownServerRoles   = @{}
        OwnerByDb          = @{}
    }

    # A login mapped as a database's owner (dbo) already has full rights in it and cannot also
    # hold a separately-named user in that database - used to skip create-user/role-sync for it.
    # SUSER_SNAME(sid) - i.e. called WITH a parameter - is not supported against Azure SQL
    # Database (error 40507); resolve the name via a join instead, same pattern as the server-role
    # resolution below. Confirmed working against both Azure SQL Database and VM-hosted SQL Server
    # when run against master (the default database for this query).
    $ownerRows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        SELECT d.name, COALESCE(sp.name, sl.name) AS OwnerLogin
        FROM sys.databases d
        LEFT JOIN sys.server_principals sp ON sp.sid = d.owner_sid
        LEFT JOIN sys.sql_logins        sl ON sl.sid = d.owner_sid
"@
    foreach ($row in $ownerRows) { $snapshot.OwnerByDb[$row.name] = $row.OwnerLogin }

    foreach ($dbName in $AllDatabasesOnServer) {
        $principals = @{}
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
            -Query "SELECT name FROM sys.database_principals WHERE type IN ('E','S','X') AND name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys') AND name NOT LIKE '##%'"
        foreach ($row in $rows) { $principals[$row.name] = $true }
        $snapshot.PrincipalsByDb[$dbName] = $principals

        $knownRoles = @{}
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName `
            -Query "SELECT name FROM sys.database_principals WHERE type = 'R'"
        foreach ($row in $rows) { $knownRoles[$row.name] = $true }
        $snapshot.KnownRolesByDb[$dbName] = $knownRoles

        $roles = @{}
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName -Query @"
            SELECT dp.name AS RoleName, up.name AS MemberName FROM sys.database_role_members drm
            JOIN sys.database_principals dp ON dp.principal_id = drm.role_principal_id
            JOIN sys.database_principals up ON up.principal_id = drm.member_principal_id
"@
        foreach ($row in $rows) {
            if (-not $roles.ContainsKey($row.MemberName)) { $roles[$row.MemberName] = [System.Collections.Generic.List[string]]::new() }
            $roles[$row.MemberName].Add($row.RoleName)
        }
        $snapshot.RolesByDb[$dbName] = $roles

        $viewPerms = @{}
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName -Query @"
            SELECT u.name AS MemberName, dp.permission_name AS PermissionName FROM sys.database_permissions dp
            JOIN sys.database_principals u ON dp.grantee_principal_id = u.principal_id
            WHERE dp.permission_name LIKE 'VIEW %' AND dp.state_desc = 'GRANT'
"@
        foreach ($row in $rows) {
            $perm = $row.PermissionName -replace '^VIEW ', ''
            if (-not $viewPerms.ContainsKey($row.MemberName)) { $viewPerms[$row.MemberName] = [System.Collections.Generic.List[string]]::new() }
            $viewPerms[$row.MemberName].Add($perm)
        }
        $snapshot.ViewPermsByDb[$dbName] = $viewPerms

        $executePerms = @{}
        $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Database $dbName -Query @"
            SELECT u.name AS MemberName, 'SCHEMA::' + SCHEMA_NAME(dp.major_id) AS Target
            FROM sys.database_permissions dp
            JOIN sys.database_principals u ON dp.grantee_principal_id = u.principal_id
            WHERE dp.permission_name = 'EXECUTE' AND dp.state_desc = 'GRANT' AND dp.class = 3
            UNION ALL
            SELECT u.name AS MemberName, SCHEMA_NAME(o.schema_id) + '.' + OBJECT_NAME(dp.major_id) AS Target
            FROM sys.database_permissions dp
            JOIN sys.database_principals u ON dp.grantee_principal_id = u.principal_id
            JOIN sys.objects o ON dp.major_id = o.object_id
            WHERE dp.permission_name = 'EXECUTE' AND dp.state_desc = 'GRANT' AND dp.class = 1
"@
        foreach ($row in $rows) {
            if (-not $executePerms.ContainsKey($row.MemberName)) { $executePerms[$row.MemberName] = [System.Collections.Generic.List[string]]::new() }
            $executePerms[$row.MemberName].Add($row.Target)
        }
        $snapshot.ExecutePermsByDb[$dbName] = $executePerms
    }

    $knownServerRoles = @{}
    $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken `
        -Query "SELECT name FROM sys.server_principals WHERE type = 'R'"
    foreach ($row in $rows) { $knownServerRoles[$row.name] = $true }
    $snapshot.KnownServerRoles = $knownServerRoles

    # LEFT JOIN + COALESCE against both sys.server_principals and sys.sql_logins for role AND
    # member: on Azure SQL Database, SQL-authentication logins (e.g. a `type: sql` JSON login)
    # exist in sys.sql_logins but not in sys.server_principals, so an INNER JOIN against only
    # sys.server_principals silently drops any server-role membership held by a SQL-auth login,
    # even though sys.server_role_members correctly has the row. Confirmed empirically against a
    # real Azure SQL Database server.
    $serverRoles = @{}
    $rows = Invoke-SqlAccessQuery -SqlServer $SqlServer -AccessToken $AccessToken -Query @"
        SELECT
            COALESCE(rp.name, rsl.name) AS RoleName,
            COALESCE(mp.name, msl.name) AS MemberName
        FROM sys.server_role_members srm
        LEFT JOIN sys.server_principals rp  ON rp.principal_id = srm.role_principal_id
        LEFT JOIN sys.sql_logins        rsl ON rsl.principal_id = srm.role_principal_id
        LEFT JOIN sys.server_principals mp  ON mp.principal_id = srm.member_principal_id
        LEFT JOIN sys.sql_logins        msl ON msl.principal_id = srm.member_principal_id
        WHERE COALESCE(rp.name, rsl.name) LIKE '##%'
"@
    foreach ($row in $rows) {
        if (-not $serverRoles.ContainsKey($row.MemberName)) { $serverRoles[$row.MemberName] = [System.Collections.Generic.List[string]]::new() }
        $serverRoles[$row.MemberName].Add($row.RoleName)
    }
    $snapshot.ServerRolesByLogin = $serverRoles

    return $snapshot
}
