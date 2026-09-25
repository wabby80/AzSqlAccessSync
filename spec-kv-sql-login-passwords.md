# Spec: Key-Vault-backed password management for `type: sql` logins

Status: **draft, for review — not yet implemented.**

## 1. Problem

Today, `type: external` logins get full lifecycle management (create, fix roles/permissions,
remove drift). `type: sql` logins do not — `Sync-SqlServerLogin` explicitly refuses to create
them ("Skipping SQL login creation... passwords must not be stored in JSON") and requires a
human to create them out of band. This spec closes that gap by storing SQL login passwords in a
dedicated Azure Key Vault instead of JSON, keyed by secret name = login name, so `sql`-type
logins can be created and password-repaired the same way `external` logins already are.

## 2. Key Vault

- **Dedicated vault.** Not shared with other application secrets. Azure Key Vault's RBAC/access
  model has no per-secret ACL, so any identity with read access to the vault can read every
  secret in it — a dedicated vault keeps that blast radius limited to SQL login passwords only.
- Secret name = SQL login name (exact match). Secret value = the password.
- The identity running the module (interactive user or pipeline identity) needs:
  - `get` + `list` on the vault, always.
  - `set` as well, for the auto-generate-on-first-create path (§5, case D).
  - Grant both the data-plane RBAC role (`Key Vault Secrets Officer`, covers get/list/set) and
    ARM-level `Reader` on the vault resource — some `Az.KeyVault` versions resolve `-VaultName`
    via an internal ARM lookup before the data-plane call, so granting both up front avoids a
    version-specific permission gap.

**Profile JSON reference — confirmed.** A single `KeyVaultName` field, same pattern as the
existing `LoginIgnoreList`:

```json
{
  "LoginsFolderPath": "./../Logins",
  "SqlServer": "my-server.database.windows.net",
  "Environment": "STAGE",
  "KeyVaultName": "my-sql-secrets-kv"
}
```

No `SubscriptionId`/`ResourceGroup` needed. The module only ever does data-plane secret
read/writes (`Get`/`Set-AzKeyVaultSecret`), never an ARM-level vault lookup or listing — and Key
Vault names are globally unique across Azure, so the vault name alone fully determines the
data-plane endpoint (`https://<name>.vault.azure.net`).

## 3. Server-level auth-mode gate (once per run, not per login)

Before processing any `type: sql` login, run once against the target server:

```sql
SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS bit) AS SqlAuthDisabled
```

If `SqlAuthDisabled = 1`, SQL authentication is not permitted on this server at all — skip every
`type: sql` login for this run with one clear log line, rather than attempting and failing per
login.

Confirmed empirically (against a real Azure SQL Database and a VM-hosted SQL Server running
SQL 2025) that this property returns consistent results on both target types — no
per-server-type branching needed. The module targets both kinds, so that consistency mattered.

Even if this check were ever wrong on some future target, it fails safe: the actual
`CREATE`/`ALTER LOGIN ... WITH PASSWORD` would still be rejected by the server and land in the
existing SQL-error path. This gate is a cleaner early exit, not the safety boundary.

## 4. Test-connection primitive

A single reusable check, used in two places below: attempt a SQL-authentication connection to
the server using a given login + password, and classify the result as one of:

- **Success** — credential is valid.
- **AuthFailed** — server returned error 18456 (login failed). Treated as "this password is
  wrong" *only* in the sense of triggering a reset — see the open question in §7 about 18456
  also covering "valid login, no database access."
- **OtherError** — anything else (network, timeout, permission, unexpected). Never triggers a
  password reset on this signal — surfaces as a normal accumulated SQL error instead.

## 5. Per-login decision matrix

For each `type: sql` login declared in JSON (only reached if §3's gate allows SQL auth):

| Login exists on server? | KV secret exists? | Action |
|---|---|---|
| Yes | Yes | **Managed flow** — test-connect with the KV password (§6). |
| Yes | No | **Leave alone — confirmed.** Do not touch the password. Log clearly: "login exists but has no KV secret — not under management until one is seeded." Counted in the run summary (§7), same as any other item needing manual attention — not silently skipped. This is the safe default for every `sql`-type login that exists today, none of which have a KV secret yet. |
| No | Yes | **Create using existing secret** — `CREATE LOGIN [name] WITH PASSWORD = '<kv value>'`. |
| No | No | **Full auto-provision** — generate a strong random password, `CREATE LOGIN` with it, write it back to the vault as a new secret. |

The presence of a KV secret is the de-facto opt-in signal for "this existing login is now under
password management" — no new field is needed on the login's JSON entry. A login only starts
being password-managed once someone deliberately seeds its KV secret (with its current real
password, for a pre-existing login). This avoids a flag-day migration problem: without this,
turning the feature on would immediately reset every existing `sql`-type login's password to a
freshly generated value the first time it ran, breaking whatever currently authenticates with
the real one.

## 6. Managed flow detail (existing login + existing KV secret)

**Sequencing — this runs at the *end* of processing this login, not at the start.** The normal
per-database sync for this login (`Sync-SqlDatabaseUser`, `Sync-SqlRoleMembership`,
`Sync-SqlViewPermission`, `Sync-SqlExecutePermission` — i.e. the existing per-database loop in
`Sync-SqlUserAccess`) must run first, for all of this login's declared databases, *before* the
password check below. Testing before that point risks a false "AuthFailed" caused by the login
not yet having a database to connect to in *this run* — not because the password is wrong.

**Target database:** the first database in this login's declared list (JSON order) that was
successfully synced this run — never `master` (not every login has `master` access, confirmed —
most JSON entries don't declare a `master` database at all). Password is a
login-level (server-level) property, not per-database, so which one is tested doesn't matter
functionally — first-in-list is just a simple, deterministic tie-breaker, not a meaningful
choice. **If the login has no declared databases at all, skip this check entirely** — nothing to
test against, and no functional access depends on the password without a database mapping.

1. Pull the KV secret.
2. Test-connect (§4), targeting the chosen database.
   - **Success** → password already correct. Done, no action.
   - **OtherError** → accumulate into `$script:SyncQueryErrors` as today (fails the run like any
     other SQL error).
   - **AuthFailed** → proceed to reset:
     1. `ALTER LOGIN [name] WITH PASSWORD = '<kv value>'` (admin/AAD connection, as used
        elsewhere in this module).
     2. Test-connect again (§4), same credential.
        - **Success** → done.
        - **Failure (either kind)** → password was set, but the login still can't authenticate —
          e.g. the login is disabled, lacks CONNECT permission, was locked by an admin action in
          SSMS, or (Azure SQL specifically) the change hasn't propagated yet. **Log to a separate
          bucket and move on — does not fail the run.** This may be an intentional admin action,
          not a bug, so the module must not treat it as fatal.
3. **No retry loop.** Test → reset → verify happens once. If verify still fails, stop for this
   login and log it — never loop back and retry the reset automatically. Repeated failed
   SQL-auth attempts against the same login are themselves a signal that can trip brute-force
   detection (Microsoft Defender for SQL and similar); a single clean attempt-and-log is safer
   than a retry loop generating more failed-auth noise.

## 7. Failure visibility

Two failure categories exist outside the normal `$script:SyncQueryErrors` → throw-at-end path,
because both can reflect legitimate, intentional states rather than bugs:

- Login exists, no KV secret yet (§5, row 2).
- Login exists, KV secret exists, reset was attempted, verify still failed (§6, step 2).

Both accumulate into a separate tracker (e.g. `$script:SqlLoginVerificationWarnings`) and **do
not fail the run**. They must still be visible: surfaced prominently in the final
`=== Sync Summary ===` block (not just an inline console line during the loop), so a login
needing manual attention is visible even to someone skimming only the tail of an otherwise-green
run.

## 8. Hard security requirement (non-negotiable, independent of the above)

The password value must **never** appear in `Write-Host`/`Write-Verbose`/error output, including
inside logged SQL query text on failure. `Invoke-SqlAccessQuery`'s catch block currently does
`Write-Verbose "Failed query: $Query"` on any failure — any query built with an embedded password
(`CREATE`/`ALTER LOGIN ... WITH PASSWORD = '...'`) must have that value masked before it can ever
reach that log line, or any other log line, or the accumulated error message shown in the final
summary.

## 9. Open questions

1. ~~KV reference format in the profile JSON~~ — **Resolved.** `KeyVaultName` field on the
   Profile JSON (§3). RBAC (`Key Vault Secrets Officer` + ARM `Reader`) is the assumed access
   model.
2. ~~The 18456-ambiguity risk~~ — **Resolved by sequencing, not by empirical testing.** Moving the
   password check to the end of each login's processing (§6) — after that login's own databases
   have already been synced this run — removes the scenario that made the ambiguity dangerous: by
   the time we test, the login should already have legitimate access to the database we're
   testing against, so a failure at that point is much more likely to genuinely mean "wrong
   password." A residual edge case remains (e.g. a rare Azure SQL propagation delay between
   granting access and it taking effect), but that's exactly the kind of case §6's "verify after
   reset, log-and-move-on" step already exists to catch — it doesn't need a separate empirical
   answer of its own.
3. ~~Password generation policy~~ — **Resolved.** 12–20 characters, must include a mix of
   letters and numbers plus at least one special character. Implementation should use a
   cryptographically secure RNG (`System.Security.Cryptography.RandomNumberGenerator`, not
   `System.Random` or `System.Web.Security.Membership` — the latter isn't available in
   PowerShell 7 cross-platform), constructing the password to guarantee at least one uppercase,
   one lowercase, one digit, and one special character regardless of random length chosen in the
   12–20 range.
4. ~~Confirm the safe-default in §5, row 2~~ — **Resolved.** Login exists, no KV secret → leave
   the password alone, log it, and count it in the run summary. This is the rollout behavior for
   every currently-existing `sql`-type login, none of which have a KV secret when the feature is
   first enabled.

All four items are now resolved — nothing left open in this spec.
