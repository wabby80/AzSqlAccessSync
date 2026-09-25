# AzSqlAccessSync

PowerShell module for synchronizing Azure SQL Server access from JSON configuration files. Manages Entra ID logins, database users, roles, and VIEW permissions — and removes anything present in SQL that is not declared in JSON.

## Requirements

- PowerShell 7+
- `Az.Accounts` 2.0+
- `Az.Resources` 6.0+
- `SqlServer` 22.0+

## Workflow prerequisites (Azure SQL + Entra)

When this module is used in CI/CD workflows (for example GitHub Actions), Azure SQL must be able to resolve Entra principals for `CREATE LOGIN ... FROM EXTERNAL PROVIDER` and `CREATE USER ... FROM EXTERNAL PROVIDER`.

Required on the target Azure SQL Server:
- System-assigned managed identity enabled.
- The SQL Server managed identity assigned the Entra `Directory Readers` role.

If these are missing, every `type: external` login fails with `Msg 33134`:

```
Principal 'x' could not be resolved. Server identity is not configured.
```

### How these are set up

1. **The identity:** enable the server's system-assigned managed identity (portal, CLI, or your
   infrastructure-as-code tool).
2. **Directory Readers:** assign the role to that identity, directly or through a role-assignable
   Entra group. This needs Entra rights (e.g. Privileged Role Administrator) that a typical
   deployment pipeline identity doesn't have.

Order matters: the identity must exist before it can be given the role.

## Import

```powershell
Import-Module .\AzSqlAccessSync.psd1
```

## Examples

The `Logins\`, `Roles\` and `Profiles\` folders contain a small example setup for a fictional
organization with environments `DEV`, `TEST`, `PROD` (Azure SQL Database) and `VMPROD` (SQL
Server on a VM). Replace them with your own configuration.

| File | Shows |
|---|---|
| `Profiles\example.json`, `example-prod.json`, `example-vm.json` | One profile per target server and environment. |
| `Logins\myapp.json` | Per-environment managed identities via the `${environment}` placeholder, least-privilege roles plus `grantExecute`. |
| `Logins\reporting.json` | An Entra group with read access to several databases and `grantView`. |
| `Logins\monitoring.json` | A server role in `master` (`##MS_ServerStateReader##`) plus `VIEW` grants without any database role. |
| `Logins\support_ProdOnly.json` | Groups assigned the custom roles from `Roles\` (e.g. read vs. PIM-eligible write). |
| `Logins\developers_DevOnly.json` | Broad access in non-production only, and a pre-existing `type: sql` login. |
| `Logins\vm-sql.json` | A VM target: `msdb` roles and a custom role with a server-scope grant. |
| `Roles\Support.json` | A read-only/read-write role pair applied to every database. |
| `Roles\JobsDb.json` | Roles scoped to one database with `databases`. |
| `Roles\DatabaseCreators.json` | A role applied only in `master` (listed explicitly in `databases`). |
| `Roles\vm-Support.json` | A server-scope grant (`ALTER ANY CONNECTION`), applied via a server role on VM targets. |

## Login JSON format

Each file in the `Logins\` folder declares one or more logins and their database access:

```json
{
  "acceptedenvironments": ["DEV", "TEST", "STAGE", "PROD"],
  "logins": [
    {
      "login": "myorg${environment}myservice",
      "type": "external",
      "databases": [
        {
          "database": "MyServiceDb",
          "roles": ["db_datareader"],
          "grantView": ["DATABASE STATE", "DEFINITION"],
          "grantExecute": ["SCHEMA::dbo"]
        },
        {
          "database": "master",
          "roles": ["##MS_ServerStateReader##"]
        }
      ]
    }
  ]
}
```

| Field | Description |
|---|---|
| `acceptedenvironments` | Environments this file applies to. Must match the `-Environment` value exactly (case-sensitive). |
| `login` | Login name. Supports `${environment}` placeholder — replaced with the lowercased environment value at runtime. |
| `type` | `external` (Entra ID/AAD) or `sql`. SQL login creation is intentionally unsupported — passwords must not be stored in JSON. |
| `roles` | Database roles (e.g. `db_owner`, `db_datareader`) or server roles prefixed with `##` (e.g. `##MS_ServerStateReader##`). |
| `grantView` | Optional. `VIEW` permissions to grant, e.g. `DATABASE STATE`, `DEFINITION`. |
| `grantExecute` | Optional. Execute permissions to grant. Use `SCHEMA::schemaname` to grant execute on all objects in a schema (most common), or `schema.ProcedureName` for a specific stored procedure. |

Databases declared in JSON that do not exist on the target server are silently skipped with an `INFO` message.

### Formatting convention for `Logins/*.json`

Login files with many databases can column-align their `databases` entries for readability. When reformatting a login's `databases` array to this style:

- One entry per line: `{ "database": "Name", "roles": [...] }`, plus `"grantView"`/`"grantExecute"`
  when present, in that order.
- `"database":` — colon immediately after the key, one space, then the quoted value. No space
  before the colon (fix `"database" :"Name"` → `"database": "Name"`).
- Pad with spaces after the database value's comma so `"roles"` starts in the same column for
  every entry **in that array** — the column is set by that array's own longest database name, not
  a fixed number shared across files. At least one space even for the longest entry.
- Within `"roles"`/`"grantView"`/`"grantExecute"` array values: `, ` between items (space after
  comma, never before). Fix e.g. `"DEFINITION","X"` → `"DEFINITION", "X"`.
- One space before the closing `}` (`["db_owner"] }`, not `["db_owner"]}`).
- Trailing comma after every entry except the last one in the array (plain JSON rule, not
  alignment-specific).
- Don't otherwise change ordering, values, or which databases/roles/grants are present — this is a
  whitespace-only cleanup.

## Environment profile

Instead of specifying parameters individually, create a profile JSON:

```json
{
  "LoginsFolderPath": "./Logins",
  "SqlServer": "my-server.database.windows.net",
  "Environment": "DEV",
  "LoginIgnoreList": ["some-login-to-skip"]
}
```

## Usage

### Preview changes (no SQL executed)
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -WhatIf
```

### Verify drift only (no sync)
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Verify
```

### Sync all logins
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json
```

### Sync a single database
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Database MyAppDb
```

### Sync a single login
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Username myorg-reporting-group
```

### Combine — single login in single database
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Username myorg-reporting-group -Database MyAppDb
```

### Direct parameters (without profile)
```powershell
Sync-SqlUserAccess -LoginsFolderPath .\Logins -SqlServer my-server.database.windows.net -Environment DEV -WhatIf
```

### Force re-authentication
```powershell
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Reconnect
```

### Remove orphaned logins (not in JSON, no user in any database)
```powershell
# Preview only
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -RemoveLogin ALL -WhatIf

# Drop every eligible login
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -RemoveLogin ALL

# Drop a single named login
Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -RemoveLogin old-service-login
```

### Structured output (CI/scripted use)
```powershell
$result = Sync-SqlUserAccess -EnvProfile .\Profiles\example.json -Verify -PassThru
$result | ConvertTo-Json -Depth 6
if ($result.Drift.HasDrift) { exit 1 }
```

## Parameters

| Parameter | Description |
|---|---|
| `-EnvProfile` | Path to an environment profile JSON file. |
| `-LoginsFolderPath` | Path to the folder containing login JSON files. Required when not using `-EnvProfile`. |
| `-SqlServer` | Azure SQL Server FQDN. Required when not using `-EnvProfile`. |
| `-Environment` | Environment name to match in `acceptedenvironments` (e.g. `DEV`, `PROD`). Required when not using `-EnvProfile`. |
| `-Database` | Limit operations to a single database. Drift report is skipped when this is set. |
| `-Username` | Limit operations to a single login. Must be declared in JSON for the given environment — throws if not found. Bulk drift removal and drift report are skipped to avoid affecting other users. Can be combined with `-Database`. |
| `-RemoveLogin` | Drop server-level logins that are present in SQL, not defined in JSON, and not mapped as a user in any database. `ALL` drops every such login; an explicit login name drops just that one (throws if it isn't eligible). Requires the drift report, so cannot be combined with `-Username` or `-Database`; skipped when `-Verify` is set. |
| `-Verify` | Skip sync, run drift report only. |
| `-WhatIf` | Print all planned actions without executing any SQL. |
| `-Reconnect` | Clear the current Azure context and force re-authentication. |
| `-PassThru` | Also return a structured summary object (`Mode`, `Status`, `Changes`, `Warnings`, `Errors`, `Drift`) for scripted/CI consumption. Console output is unchanged either way. |

## What the sync does

For each login declared in JSON (filtered by environment):

1. Verifies the Entra ID principal exists before attempting login creation.
2. Creates a server-level login if missing (`CREATE LOGIN ... FROM EXTERNAL PROVIDER`).
3. Creates a database user if missing (`CREATE USER ... FROM EXTERNAL PROVIDER`).
4. Adds the user to any declared roles.
5. Grants any declared `VIEW` permissions.
6. **Removes** role memberships, VIEW permissions, execute permissions, and database users that exist in SQL but are not declared in JSON for that login.
7. **Removes** database users that exist in SQL but have no entry in JSON at all.

The drift report at the end lists:
- Logins present in SQL but not defined in any JSON file.
- Logins with no database user in any database.

> Steps 6 and 7 and the drift report are skipped when `-Username` is specified, to avoid accidentally affecting other users.

## Sync-SqlRoles

A separate, standalone function for a different concern: standing database roles (a
least-privilege baseline — e.g. `AppOperations`, `Support_RW`, `LinkedServerAdmin`) rather
than per-login access. Reads role definitions from the `Roles\` folder and ensures each
one exists, with its declared memberships and grants, on **every non-system database** on
the target server by default — regardless of whether anyone is currently assigned to the
role. Roles are a standing definition, not tied to a specific login. A role can instead be
scoped to specific databases via the optional `databases` field (see below); an
undocumented-role check in a database it isn't scoped to still treats it as undocumented.

Deliberately much simpler than `Sync-SqlUserAccess`: there's no pre-fetch snapshot or
diffing. Every statement (`CREATE ROLE` guarded with `IF NOT EXISTS`, `ALTER ROLE ... ADD
MEMBER`, `GRANT`) is re-run unconditionally on every invocation, relying on those
statements' own idempotency (safe to repeat, no error if already applied) rather than
PowerShell-side state tracking. It does not remove memberships or grants — one added
outside these JSON files is left alone (no drift detection there).

It does detect **undocumented roles**: custom database roles that exist in SQL but aren't
declared in any `Roles/*.json` file for the current environment (e.g. a role someone
created by hand, or one whose JSON definition was since renamed/removed). These are always
reported — in the console output and, with `-PassThru`, the summary's `UndocumentedRoles`
field — and only actually dropped when `-Force` is also passed. A custom role is
distinguished from a built-in one (`db_owner`, `db_datareader`, etc.) via
`sys.database_principals.is_fixed_role`, not a hardcoded name list.

`-WhatIf` and `-Force` combine as follows for an undocumented role:

| `-WhatIf` | `-Force` | Message | Recorded as a planned change? |
|---|---|---|---|
| ✗ | ✗ | `Undocumented role [X] in db (not in any Roles/*.json - rerun with -Force to drop)` | No |
| ✗ | ✓ | `Dropping undocumented role [X] in db (not in any Roles/*.json)` — executes | N/A (executed) |
| ✓ | ✓ | `[WhatIf] Would drop undocumented role [X] in db` | Yes |
| ✓ | ✗ | `[WhatIf] Would drop undocumented role [X] in db (if -Force'd)` — informational only | No |

### Role JSON format

Same two-level shape as `Logins/*.json`: `acceptedenvironments` applies to the whole file,
and `roles` is always an array — even a file defining a single role — so one file can hold
several related roles (e.g. a read-only/read-write pair):

```json
{
  "acceptedenvironments": ["PROD"],
  "roles": [
    {
      "role": "AppOperations",
      "memberOf": ["db_datareader", "db_datawriter", "db_ddladmin"],
      "grantExecute": true,
      "grants": ["VIEW DATABASE STATE", "KILL DATABASE CONNECTION"]
    },
    {
      "role": "ReportingReadOnly",
      "databases": ["ReportingDb"],
      "memberOf": ["db_datareader"],
      "grantExecute": false
    }
  ]
}
```

| Field | Description |
|---|---|
| `acceptedenvironments` | Environments this file's roles apply to, matched against the profile's `Environment`. |
| `roles` | Array of role definitions in this file. |
| `roles[].role` | The role name to create. |
| `roles[].databases` | Optional. Database names this role is scoped to. Omit for the default — every non-system database on the server. `master` is never part of the default; list it explicitly to apply the role there (undocumented-role detection is not run in `master`). |
| `roles[].memberOf` | Fixed or custom database roles this role should be a member of (e.g. `db_datareader`, `db_datawriter`, `db_ddladmin`). |
| `roles[].grantExecute` | `true` to `GRANT EXECUTE TO` the role (covers stored procedures and scalar functions database-wide). |
| `roles[].grants` | Optional. Any other database-level `GRANT ... TO` permissions, given as the full permission phrase (e.g. `"VIEW DATABASE STATE"`, `"KILL DATABASE CONNECTION"`). |

### Document mode (`-Document`)

Reverse direction from the rest of `Sync-SqlRoles`: instead of applying JSON to SQL, reads
SQL and writes JSON. Given a database name, finds every custom role in that database that
isn't declared in any `Roles/*.json` for the current environment (fixed/built-in roles
excluded, same `is_fixed_role` check as undocumented-role detection), captures its current
`memberOf`/`grantExecute`/`grants`, and writes them to
`Roles/<database>_<yyyy-MM-dd>_documented.json` in the same shape as any other role file —
pre-scoped to that database via `databases`, with `acceptedenvironments` pre-filled from the
profile's own `Environment` (whatever environment you ran `-Document` against is exactly the
one it's confirmed correct for). Still worth a review before folding it in properly — rename
the file, and double check the captured grants are actually wanted rather than just "whatever
was already there." Read-only against SQL (no `CREATE`/`ALTER`/`DROP`); `-WhatIf`/`-Force` are
ignored. If nothing is undocumented, no file is written.

### Usage

```powershell
Sync-SqlRoles -EnvProfile .\Profiles\example.json -WhatIf
Sync-SqlRoles -EnvProfile .\Profiles\example.json

# Report undocumented roles only (default) vs. also drop them:
Sync-SqlRoles -EnvProfile .\Profiles\example.json -Force -WhatIf   # preview what would be dropped
Sync-SqlRoles -EnvProfile .\Profiles\example.json -Force           # actually drop them

# Draft a Roles/*.json from what's already in a database:
Sync-SqlRoles -EnvProfile .\Profiles\example.json -Document MyAppDb
```

| Parameter | Description |
|---|---|
| `-EnvProfile` | Path to an environment profile JSON file (`SqlServer` + `Environment`; same profiles `Sync-SqlUserAccess` uses). Required. |
| `-WhatIf` | Print all planned actions without executing any SQL. |
| `-PassThru` | Also return a structured summary object (`Mode`, `Status`, `Changes`, `Warnings`, `Errors`) for scripted/CI consumption. |

## Get-SqlAccessReport

Reports who actually has access to a database — resolved all the way down to real principals,
not just the login/group named in JSON. Reads `Logins/*.json` and `Roles/*.json` for the given
environment (the same source of truth `Sync-SqlUserAccess` enforces onto SQL) and fully expands
both nesting dimensions:

- **Roles.** A role assigned to a login — built-in (`db_owner`) or a custom role from
  `Roles/*.json` (e.g. `Support_RW`) — is expanded through any further role nesting down to its
  terminal, effective grants (`db_datareader`, `EXECUTE`, `VIEW DATABASE STATE`, ...), while still
  recording the role name(s) that led there.
- **Entra groups.** An `external` login that's a security group is walked recursively — including
  nested groups — down to the actual Users, Managed Identities, and Service Principals inside it.
  A `type: sql` login is already a leaf and skips Entra resolution entirely.
- **PIM-for-Groups eligibility.** A plain group-membership lookup only sees currently-*active*
  members — someone with an eligible assignment they haven't activated yet is invisible to it,
  which would otherwise report that branch as empty even though they could self-elevate into real
  access at any time. This is checked separately and surfaced via `MembershipState`: `Active` for
  a real current member, `Eligible` for someone who could activate into it but hasn't. Once any
  hop in a chain is `Eligible`, every leaf below it is too (access below an unactivated gate isn't
  real either).
- **The server's Microsoft Entra admin.** An ARM-level property on the logical server (Terraform
  `azuread_administrator`), not anything declared in JSON, grants that identity sysadmin-equivalent
  access to *every* database on the server. This is looked up via `Get-AzSqlServer`/
  `Get-AzSqlServerActiveDirectoryAdministrator` (an ARM call, not a SQL connection) and resolved the
  same way as any other Entra login or group. These rows always come first in the output and cover
  every database the report already covers, regardless of `-Database` — that access isn't scoped
  to one database at all.

**This never queries the target SQL server itself** — it reports the declared/enforced state from
JSON plus the server's ARM-level Entra admin setting, not a live snapshot of SQL. If
`Sync-SqlUserAccess` hasn't been run recently for this environment, run `Sync-SqlUserAccess
-Verify` first if you're unsure the two still match.

Output is one row per (database, permission, resolved leaf principal) — `Database`,
`GrantedToLogin`, `LoginType`, `RoleChain`, `EffectivePermission`, `GroupChain`,
`ResolvedPrincipal`, `ResolvedPrincipalType`, `MembershipState` — so the same person appears once
per database they can reach, through whatever path got them there.

> Checking PIM eligibility authenticates separately via `Microsoft.Graph.Authentication`
> (`Connect-MgGraph`), **not** the existing Az sign-in used everywhere else in this module — the app
> `Connect-AzAccount` signs into has a fixed permission set that does not include
> `PrivilegedEligibilitySchedule.Read.AzureADGroup` at all, so no Az token can ever carry it no
> matter what directory role the signed-in user holds (Global Admin included). The first PIM check
> in a session installs `Microsoft.Graph.Authentication` if needed and prompts once for consent to
> that scope. If the connection or call still fails, it's reported as a console warning per group
> and treated as "no eligible members" rather than failing the report.

### Usage

```powershell
# Whole server, printed to the console
Get-SqlAccessReport -EnvProfile .\Profiles\example.json

# One database, exported to a formatted spreadsheet
Get-SqlAccessReport -EnvProfile .\Profiles\example.json -Database MyAppDb -ExportToExcel

# Pipe the flat rows into your own scripting/filtering
$rows = Get-SqlAccessReport -EnvProfile .\Profiles\example.json -PassThru
```

| Parameter | Description |
|---|---|
| `-EnvProfile` | Path to an environment profile JSON file (`LoginsFolderPath` + `SqlServer` + `Environment`; same profiles `Sync-SqlUserAccess` uses). |
| `-LoginsFolderPath` / `-Environment` / `-SqlServer` | Direct parameters, used instead of `-EnvProfile`. `-SqlServer` is only used to look up the server's Entra admin via ARM — this report never connects to SQL itself. |
| `-Database` | Limit the report to a single database. Omit to report on every database declared in JSON. The server Entra admin's rows are still included for this one database, since that access isn't scoped by `-Database` at all. |
| `-ExportToExcel` | Write the report to a formatted `.xlsx` — a bold "SQL Access Report" title and generated-on date above the table, a light-blue-filled bold header row, autofilter, and the header row frozen while scrolling — in addition to the console output, then open it. The [`ImportExcel`](https://github.com/dfinke/ImportExcel) module — **not** a hard dependency of this module — is installed automatically on first use if it isn't already present. |
| `-ExportPath` | Output path for `-ExportToExcel`. Defaults to `<Desktop>\SQLAccessReport_<Environment>_(<Database>_)<yyyyMMdd>.xlsx` — the `<Database>_` segment only appears when `-Database` was specified. |
| `-PassThru` | Return the flat report rows as objects, for further scripting/piping. |

Console output for the routine "ensuring X" confirmations is behind `-Verbose` (they fire
on every single run regardless of whether anything actually changed, by design — see
above — so they'd otherwise be noise). `-WhatIf`'s planned-action output is unaffected.
