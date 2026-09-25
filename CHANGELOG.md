# Changelog

All notable changes to the AzSqlAccessSync module are recorded here.

## 0.10.1

### Fixed

- **Drift report failed on Azure SQL Database** with `Invalid object name 'sys.server_permissions'`
  (Msg 208), marking every `Sync-SqlUserAccess` run against Azure SQL Database as `FAILED`. The
  server-level access check added in 0.8.0 queried `sys.server_permissions`, which only exists on
  SQL Server. On Azure SQL Database it now checks server role membership only
  (`sys.server_role_members`), which covers the only server-level access that platform has.
  VM/on-prem SQL Server behavior is unchanged. (`Private/Get-SqlAccessDriftReport.ps1`)

## 0.10.0

### Changed

- **Breaking: role definitions are read from the profile's `RolesFolderPath`.** Previously
  `Sync-SqlRoles` and `Get-SqlAccessReport` always read the `Roles` folder inside the module,
  which after `Install-Module` is the installed module's folder and gets replaced by
  `Update-Module`. `RolesFolderPath` is resolved like `LoginsFolderPath` (relative to the profile
  file unless rooted).
  - `Sync-SqlRoles` requires it and throws if the profile has none. There is deliberately no
    fallback to the module's own `Roles` folder, which only holds examples.
  - `Get-SqlAccessReport` takes it from the profile or the new `-RolesFolderPath` parameter. It's
    optional there: without it, custom roles are reported unexpanded, with a warning.
  - To migrate, add `"RolesFolderPath": "<path to your Roles folder>"` to each profile.

### Added

- **Example configuration.** `Logins/`, `Roles/` and `Profiles/` hold a small fictional setup,
  described in the README's "Examples" section.
- **`Publish.ps1`.** Publishes from a staging folder containing only an allow-list of module files,
  so repository-only files never end up in the package. Supports `-WhatIf`.

## 0.9.0

### Added

- **`Sync-SqlRoles` applies roles to master when explicitly scoped there.** master was never
  part of the per-database loop, so a role with `"databases": ["master"]` was silently skipped.
  A role that lists `master` in `databases` is now applied there (`CREATE ROLE` if not exists,
  memberships such as `dbmanager`, grants). Roles without `databases` still never touch master,
  and in master only the master-scoped definitions apply. Undocumented-role detection/removal is
  not run in master.

## 0.8.0

### Added

- **`Sync-SqlRoles` handles server-scope grants on VM/on-prem SQL Server.** Adds the same
  `Azure SQL Database: True/False` preflight as `Sync-SqlUserAccess` (`Test-AzureSqlServer`). When
  the target isn't Azure SQL Database, any `grants` entry that is a server-scope permission (e.g.
  `ALTER ANY CONNECTION`) is no longer attempted in every database - which failed with Msg 4621
  ("Permissions at the server scope can only be granted when the current database is master") -
  but applied once in master to a server role of the same name (`CREATE SERVER ROLE` if not
  exists + `GRANT`). No JSON change needed: which permissions are server-scope is read at runtime
  from `sys.fn_builtin_permissions('SERVER')` minus those also present at `'DATABASE'` scope.
  Azure SQL Database behavior is unchanged. Adding logins to the new server role is not yet
  handled.
- **Undocumented server roles.** On the same non-Azure targets, custom server roles in master
  that no role definition for this environment has a server-scope grant for any more (grant
  removed from the JSON, or the whole role removed) are reported as undocumented and, with
  `-Force`, dropped (`DROP SERVER ROLE`) - the server-level counterpart of the existing
  per-database undocumented-role handling. Listed in the summary / `UndocumentedRoles` with
  `Database = 'master'`. Fixed server roles (`sysadmin`, `##MS_...##`, ...), `public`, and the
  SQL IaaS Agent extension's own roles (`SqlIaaSExtension_*`, e.g.
  `SqlIaaSExtension_StatusReporting`) are never candidates.

### Changed

- **`-RemoveLogin` eligibility is much stricter (both Azure SQL Database and VM).** Previously
  "not mapped" only looked for a same-named user in the databases named in JSON (master
  excluded), and the `sys.sql_logins` side of the login query had no system-login filter, so on
  the VM `-RemoveLogin ALL` would have targeted `sa`, the `##MS_Policy...##` logins, and sysadmin
  members. A login is now only listed under "Logins present in SQL with no database user and no
  server-level access" (renamed from "...not mapped as a user in any database") - and so only
  removable - when it is not a system login (`sa`, `##...##`, `principal_id < 256`), is a user
  in no database on the server (every database plus master, and msdb on non-Azure; matched by
  name or SID), holds no server role membership and no server permission beyond `CONNECT SQL`,
  and owns no database (and, on non-Azure, no SQL Agent job). `Get-SqlAccessDriftReport` takes a
  new `-IsAzureSqlServer`. Login removal is also skipped entirely if any SQL query in the run
  failed, since a failed lookup would make a login look unused.

## 0.6.0

### Added

- **`Get-SqlAccessReport` — new public function reporting resolved database access.** Reads
  `Logins/*.json` and `Roles/*.json` for an environment (the same source of truth
  `Sync-SqlUserAccess` enforces onto SQL) and reports who actually ends up with access, fully
  resolved rather than stopping at the login/group name declared in JSON:
  - **Role nesting.** A role assigned to a login — built-in or a custom role from `Roles/*.json`
    (e.g. `Support_RW`, `AppOps_RW`) — is expanded recursively through `memberOf` (which can itself
    name another custom role) down to its terminal, effective grants, while keeping the role
    name(s) that led there (new private `Expand-SqlRoleChain.ps1`, cycle-guarded).
  - **Entra group nesting.** An `external` login that's a security group is walked recursively —
    including nested groups — down to the actual Users, Managed Identities, and Service
    Principals inside it, via `Get-AzADGroupMember`/`Get-AzADUser`/`Get-AzADServicePrincipal`
    (new private `Resolve-EntraObject.ps1`, `Expand-EntraPrincipalChain.ps1`,
    `Expand-ResolvedEntraObject.ps1`; cycle-guarded, and caches every resolved object by ObjectId
    so the same group/user is never looked up twice in one run). A `type: sql` login is already a
    leaf and skips Entra resolution entirely.
  - Deliberately **never queries the target SQL server** — this reports the declared/enforced
    JSON state, not a live snapshot; run `Sync-SqlUserAccess -Verify` first if that's in doubt.
  - Output is one flat row per (database, permission, resolved leaf principal) — `Database`,
    `GrantedToLogin`, `LoginType`, `RoleChain`, `EffectivePermission`, `GroupChain`,
    `ResolvedPrincipal`, `ResolvedPrincipalType` — sorted by database first. Supports `-Database`
    (single-database filter), `-PassThru` (returns the flat rows), and `-ExportToExcel` (writes a
    single-sheet, autofiltered, frozen/bold-header `.xlsx` colored by `ResolvedPrincipalType`,
    via the `ImportExcel` module — a soft dependency, lazily imported only when this switch is
    used, deliberately **not** added to this module's `RequiredModules`, so `Import-Module
    AzSqlAccessSync` still works for everyone else without it installed).
  - New private `Import-RoleConfig.ps1` extracts the `Roles/*.json` loader that was previously
    inlined in `Sync-SqlRoles.ps1` (which is untouched and still uses its own inline copy) so this
    command can reuse the same parsing without duplicating Sync-SqlRoles' own logic verbatim.
  - `-ExportToExcel`'s `ImportExcel` dependency is installed automatically (new private
    `Initialize-ImportExcelModule.ps1`) rather than requiring a manual `Install-Module` step, and
    checked as a pre-flight (before the role/Entra expansion work runs) so a failed install fails
    fast.
  - `Write-Progress` reports per-login progress while expanding roles/Entra groups, matching
    `Sync-SqlUserAccess`'s progress bar - resolving every group in a large environment can take a
    while, and a bare console otherwise looks hung.
  - `-ExportToExcel`'s default path is now `<Desktop>\SQLAccessReport_<Environment>_(<Database>_)
    <yyyyMMdd>.xlsx` (the Database segment only when `-Database` was specified), and the file is
    opened automatically once written (skipped when `$env:CI` is set).
  - New `MembershipState` column (`Active`/`Eligible`) fixes a real gap: `Get-AzADGroupMember` only
    ever sees a group's currently-*active* members, so a PIM-for-Groups eligible assignment nobody
    has activated yet was invisible - the whole branch silently reported as `(empty group)` even
    though those people can self-elevate into real access at any time. New private
    `Get-EntraGroupPimEligibleMembers.ps1` queries Microsoft Graph's PIM-for-Groups eligibility
    schedule directly (no Az.Resources cmdlet exists for it). `Resolve-EntraObject.ps1` and
    `Expand-ResolvedEntraObject.ps1` propagate the eligible-vs-active state through the whole chain
    - once any hop is only eligible, every leaf below it is marked `Eligible` too, since access
    below an unactivated gate isn't real either.
  - The PIM eligibility check authenticates via `Microsoft.Graph.Authentication`
    (`Connect-MgGraph`/`Invoke-MgGraphRequest`, new private `Initialize-PimGraphConnection.ps1`),
    **not** the existing Az token used everywhere else in this module - confirmed empirically
    (403 from Microsoft Graph even when signed in as Global Admin) that the app
    `Connect-AzAccount` signs into has a fixed, Microsoft-registered permission set that does not
    include `PrivilegedEligibilitySchedule.Read.AzureADGroup` at all, so no Az token can ever carry
    it regardless of the signed-in user's directory role - being Global Admin controls directory
    role membership, not what scopes a given client application is registered to request.
    Microsoft Graph PowerShell's own app is designed for incremental scope consent and does
    support it. `Microsoft.Graph.Authentication` is a soft dependency (same pattern as
    `ImportExcel` - not in `RequiredModules`, installed and connected automatically, one-time
    interactive consent prompt) triggered lazily only the first time a PIM eligibility check is
    actually attempted, so a run against an environment with no PIM-for-Groups usage never needs
    it. If the connection or call still fails, that group is reported as a console warning and
    treated as having no eligible members, rather than failing the whole report.
  - `-ExportToExcel` layout revised: the row-coloring-by-`ResolvedPrincipalType`/`MembershipState`
    conditional formatting was removed (it forced a solid fill on every cell in those columns,
    including a white fill on non-matching rows, which suppressed Excel's gridlines for the whole
    sheet - not just the intended highlighted rows). The table now starts a few rows down (row 4)
    to leave room for a bold "SQL Access Report" title (row 1) and a "Generated: <date>" line (row
    2), and the header row (row 4) gets a plain light-blue fill instead. The freeze pane is now set
    explicitly to the header row via `$worksheet.View.FreezePanes()` rather than `-FreezeTopRow`,
    which always freezes literal row 1 (the title, once the table is no longer at the top) instead
    of wherever the header actually landed.
  - **Fixed:** `-ExportToExcel`'s default filename is date-based with no time component, so
    re-running the report again the same day reused the same file - and `Export-Excel` doesn't
    clear a worksheet before writing, it only overwrites the cells it explicitly writes. Stale
    header/data rows and conditional-formatting rules left behind by an earlier run today (e.g.
    from before the row-4 layout change, or from the coloring this version removes above) stayed
    in the file underneath/around each new run's output - visible as duplicate headers mixed into
    the title rows, and colors persisting on `ResolvedPrincipalType`/`MembershipState` even after
    the code stopped adding them. The existing file is now deleted before every export, so each run
    starts from a completely clean sheet; if it can't be deleted (most likely because it's still
    open in Excel, which this command opens automatically), that's now a clear error instead of a
    silently corrupted-looking report.

## 0.7.0

### Added

- **`Get-SqlAccessReport` now includes the server's Microsoft Entra admin.** That admin (Terraform
  `azuread_administrator` / `azurerm_mssql_active_directory_administrator`) is an ARM-level
  property of the logical server, not anything declared in `Logins/*.json`, and grants that
  identity sysadmin-equivalent access to *every* database on the server - invisible to a purely
  JSON-driven report unless looked up separately. New private `Get-SqlServerEntraAdmin.ps1` finds
  it via `Get-AzSqlServer`/`Get-AzSqlServerActiveDirectoryAdministrator` (an ARM/control-plane
  call, not a SQL connection, so this still never queries the target SQL server itself), matching
  by the server's short name against whatever Azure subscription is currently selected. The
  resolved admin (user or group) is expanded through the same Entra group-nesting and PIM
  eligibility machinery as any other login. These rows are always placed first in the output and
  cover every database the report already covers regardless of `-Database`, since that access
  isn't scoped to one database at all.
  - New `-SqlServer` parameter (mandatory in the `Direct` parameter set; read from the profile's
    existing `SqlServer` field under `-EnvProfile`, which this report previously ignored entirely).
  - If the server isn't found in `Get-AzSqlServer` at all - expected for a VM-hosted target, which
    has no such ARM resource, or if the wrong subscription is currently selected - this is silently
    skipped: no admin rows, no warning. Same silent skip if the server exists but has no Entra
    admin configured.
  - **New hard dependency: `Az.Sql`** (added to `RequiredModules` alongside `Az.Accounts`/
    `Az.Resources`/`SqlServer`), since this runs unconditionally on every `Get-SqlAccessReport`
    call rather than behind an opt-in switch like `-ExportToExcel`'s `ImportExcel`.



### Added

- **`-RemoveLogin` parameter on `Sync-SqlUserAccess`.** Drops server-level logins that are
  orphaned in both senses the existing drift report already detected but never acted on: present
  in SQL, not defined in any JSON file, and not mapped as a user in any database. Pass `ALL` to
  drop every such login, or an explicit login name to drop just that one (throws if the named
  login isn't in that eligible set — e.g. it's still declared in JSON, or it still has a database
  user somewhere). Requires the drift report to compute eligibility, so it cannot be combined with
  `-Username`/`-Database`, and is skipped (with a message, not silently) when `-Verify` is set,
  since `-Verify` means report-only. Honors `-WhatIf`. New private helper
  `Remove-SqlOrphanedLogin.ps1` issues the `DROP LOGIN`, recorded via the existing `Add-SyncAction`
  mechanism like every other change/warning in the run. Naming an explicit login that no longer
  exists on the server (e.g. it was already dropped by a prior run) logs "not found on server —
  skipping" instead of throwing; naming one that exists but genuinely isn't eligible (still in
  JSON, or still mapped as a user in some database) still throws. This distinction needed
  `Get-SqlAccessDriftReport` to also return `AllServerLogins`, the full current login list it was
  already querying internally.

## 0.4.0

### Added

- **`Sync-SqlRoles` — standalone role-definition sync.** New public function, separate from
  `Sync-SqlUserAccess`, that ensures the standing database roles defined in `Roles/*.json` (role
  name, `memberOf`, `grantExecute`, `grants`) exist on every non-system database on the target
  server, regardless of whether anyone is currently a member. Same two-level JSON shape as
  `Logins/*.json` — `acceptedenvironments` per file, `roles` always an array — so one file can
  define several related roles. Deliberately much simpler than
  `Sync-SqlUserAccess`: no pre-fetch snapshot or diffing — every statement (`CREATE ROLE` guarded
  with `IF NOT EXISTS`, `ALTER ROLE ... ADD MEMBER`, `GRANT`) is re-run unconditionally on every
  invocation, relying on those statements' own idempotency rather than PowerShell-side state
  tracking. No drift detection or revocation — a grant added outside the JSON is left alone.
  Supports `-EnvProfile`, `-WhatIf`, `-PassThru` (same summary shape as `Sync-SqlUserAccess`, minus
  `Drift` but with `UndocumentedRoles`), `-Force`, and `-Document`. Detects "undocumented roles" —
  custom database roles present in SQL but not declared in any `Roles/*.json` for the environment,
  found via `sys.database_principals.is_fixed_role` rather than a hardcoded name list — and reports
  them unconditionally; `-Force` additionally drops them (`-WhatIf` still previews without
  executing, and always names the specific `DROP ROLE` it would run, noting "(if -Force'd)" when
  `-Force` itself isn't set). A role definition can carry an optional `databases` field to scope it
  to specific databases instead of every database on the server (the default when omitted) — this
  also narrows what counts as "documented" for undocumented-role detection on a per-database basis.
  `-Document <database>` runs read-only against SQL and writes every undocumented custom role in
  that one database, with its current `memberOf`/`grantExecute`/`grants`, to a new
  `Roles/<database>_<yyyy-MM-dd>_documented.json` — pre-scoped to that database via `databases` and
  to the profile's own `Environment` via `acceptedenvironments`, since that's the environment it was
  just confirmed to reflect.

### Fixed

- **`SUSER_SNAME` failure on Azure SQL Database.** The dbo-owner-skip lookup added in `0.3.0`
  (`Get-SqlAccessSnapshot`'s `OwnerByDb`) called `SUSER_SNAME(owner_sid)` — i.e. with a parameter —
  which Azure SQL Database rejects with error 40507 ("cannot be invoked with parameters in this
  version of SQL Server"). Replaced with a join against `sys.server_principals`/`sys.sql_logins`,
  the same pattern already used a few lines below for server-role resolution. Confirmed working
  against both Azure SQL Database and VM-hosted SQL Server.
- **`msdb` snapshotted/queried on Azure SQL Database, where it isn't reachable via AAD token
  auth.** `Sync-SqlUserAccess` unconditionally added `'msdb'` to the snapshot database list and the
  per-login database filter for every server, to support VM-only logins with `msdb` access — but
  Azure SQL Database has no real `msdb`, so every run against an Azure SQL Database server failed
  5 separate queries with "Login failed for
  user '<token-identified principal>'". Added `Test-AzureSqlServer` (`SERVERPROPERTY('EngineEdition')
  = 5`, the documented way to detect Azure SQL Database specifically, as opposed to Managed
  Instance/VM/on-prem which all have a real `msdb`) as a one-time pre-flight check; `'msdb'` is now
  only included in the special-database set when the target is not Azure SQL Database.

## 0.3.0

### Added

- **`-PassThru` switch for structured output.** `Sync-SqlUserAccess` now optionally returns a
  summary object (`Mode`, `Status`, `Changes`, `Warnings`, `Errors`, `Drift`) in addition to its
  normal console output, for CI/scripted consumption (e.g.
  `$result = Sync-SqlUserAccess ... -PassThru; $result | ConvertTo-Json`). Console output is
  unchanged when `-PassThru` is not specified — `Write-Host` writes to a separate stream from the
  pipeline, so no existing interactive behavior changes.
  - Every create/grant/remove/revoke action (across `Sync-SqlServerLogin`,
    `Sync-SqlDatabaseUser`, `Sync-SqlRoleMembership`, `Sync-SqlViewPermission`,
    `Sync-SqlExecutePermission`, `Remove-SqlAccessDrift`, and the bulk drift-removal loop in
    `Sync-SqlUserAccess`) is now recorded via a new `Add-SyncAction` helper
    (`Private/Add-SyncAction.ps1`), tagged with whether it was planned (`-WhatIf`) or executed,
    and split into `Changes` vs `Warnings` (e.g. a missing Entra ID principal, an unsupported
    login type) in the summary.
  - `Get-SqlAccessDriftReport` now also returns its findings (`HasDrift`, `ExtraUsers`,
    `LoginsNotInJson`, `LoginsWithNoDb`) as an object, surfaced under the summary's `Drift` field,
    in addition to its existing console report.
  - This is a step toward CI/CD gating — the module reports state, the calling workflow decides
    what should fail a build (e.g. `$result.Drift.HasDrift`).

## 0.2.0

### Fixed

- **`Get-AzSqlToken`: redundant `Enable-AzContextAutosave` call.** Called twice at the top of the
  function; the second call lacked `-ErrorAction SilentlyContinue`, producing a noisy, confusing
  error on CI runners without a writable profile path. Removed the redundant second call.
- **Server-role membership check missed SQL-authentication logins.** The query resolving "is this
  login already a member of this `##`-prefixed server role" joined against `sys.server_principals`
  only. On Azure SQL Database, a `type: sql` (SQL-authentication) login exists in `sys.sql_logins`
  but not in `sys.server_principals` — confirmed empirically against a real production server — so
  the check always reported "not a member" for such logins even immediately after a successful
  `ALTER SERVER ROLE ... ADD MEMBER`, causing the module to repeatedly re-issue the same grant every
  run. Fixed by resolving both the role and member name via `LEFT JOIN` + `COALESCE` against both
  `sys.server_principals` and `sys.sql_logins`.
  (`Private/Get-SqlAccessSnapshot.ps1`)
- **Access snapshot didn't cover `master`.** The performance work below built its shared snapshot
  only over the server's non-system databases, but `master` is a legitimate, always-allowed target
  for server-role grants (and for `master`-scoped database-level roles like `dbmanager`). This
  crashed `Sync-SqlRoleMembership` ("Cannot index into a null array") for any login with a
  `master`-scoped role, and would have silently mis-evaluated database-level `master` roles as
  never-a-member. Fixed by including `master` in the snapshot's database list, plus added
  null-guards for the same lookup pattern in the three grant-side functions.
  (`Public/Sync-SqlUserAccess.ps1`, `Private/Sync-SqlRoleMembership.ps1`,
  `Private/Sync-SqlViewPermission.ps1`, `Private/Sync-SqlExecutePermission.ps1`)
- **`-Database`/`-OneDatabase` never validated the supplied name.** A typo'd `-Database` value was
  passed straight through with no check against what actually exists on the server, producing a
  confusing cascade of Azure SQL's deliberately-vague "Login failed for user
  '\<token-identified principal\>'" errors instead of one clear message. Fixed by validating
  `-OneDatabase` against the server's real database list up front and throwing a clear
  `"Database 'X' does not exist on server 'Y'."` immediately if it isn't found.
  (`Public/Sync-SqlUserAccess.ps1`)
- **Database-user drift scans didn't exclude Azure's own platform-managed system principals.** The
  three places that enumerate "real" database users (bulk removal, the drift report, and the
  snapshot) excluded only `dbo`/`guest`/`INFORMATION_SCHEMA`/`sys`, not Azure SQL Database's
  `##MS_*##`-patterned system principals (e.g. `##MS_JobAccount##`, `##MS_JobsResourceManager##` —
  provisioned automatically for the Elastic Database Jobs feature). Without this fix, a real
  (non-`-WhatIf`) run would have `DROP USER`'d these legitimate, Azure-managed accounts. Fixed by
  excluding `##`-prefixed names in all three queries, matching how server-role queries already
  handled this elsewhere in the module.
  (`Public/Sync-SqlUserAccess.ps1`, `Private/Get-SqlAccessDriftReport.ps1`,
  `Private/Get-SqlAccessSnapshot.ps1`)

### Changed

- **Performance: replaced per-login/per-role/per-permission SQL round trips with a single upfront
  snapshot.** Previously, checking "is this login already granted this role/permission" issued a
  live query per role and per permission, per login, per database — and drift removal separately
  queried once per (login, database) pair regardless of whether that login even touched that
  database. Both sides now read from one shared `Get-SqlAccessSnapshot` read, taken once per run,
  collapsing the query count from O(logins × databases × items) to a fixed cost per run
  (roughly `5 × databases + 2` queries total). (`Private/Get-SqlAccessSnapshot.ps1`, new;
  `Private/Sync-SqlRoleMembership.ps1`, `Private/Sync-SqlViewPermission.ps1`,
  `Private/Sync-SqlExecutePermission.ps1`, `Private/Remove-SqlAccessDrift.ps1`,
  `Public/Sync-SqlUserAccess.ps1`)
- **Reformatted all `Logins/*.json` files** so each database entry sits on one line
  (`{ "database": "X", "roles": [...] }`) instead of spanning several — readable for logins with
  many permissions. Content verified unchanged, formatting only.

### Added

- Full design spec for Key-Vault-backed password management of `type: sql` logins
  (`spec-kv-sql-login-passwords.md`) — closes the gap where SQL-authentication logins currently
  require manual creation, since passwords can't be stored in JSON. **Not yet implemented** —
  deliberately deferred pending Key Vault infrastructure prep.

## 0.1.0

Initial release. `Sync-SqlUserAccess` syncs Azure SQL logins, database users, roles, and VIEW/EXECUTE
permissions from JSON configuration, including drift detection and removal. Supports Entra ID
(`external`) and pre-existing SQL (`sql`) logins, `-Username`/`-Database` scoping, `-Verify`,
`-WhatIf`, and `-Reconnect`.
