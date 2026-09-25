# PowerShell Gallery readiness

Checklist for publishing AzSqlAccessSync to the public PowerShell Gallery. Written in the original
(internal) repo before the module folder was copied to its own repository, so a fresh session in
the new repo can pick up where this left off.

## Decisions already made

- **The whole module folder is published as-is** — no build step or `FileList` filtering. Anything
  in the folder at publish time ends up in the package.
- **New repository, no git history.** The folder is copied, not split, so earlier versions of the
  config files are not carried over.
- **`Logins/`, `Roles/` and `Profiles/` are replaced with examples** — the original organization's
  real configuration is removed and each folder gets example files showing the format instead.
  Done: a fictional DEV/TEST/PROD/VMPROD setup, described in the README's "Examples" section.

## Remaining work

### Blockers

1. **Organization-specific references — done.** README, CHANGELOG, the KV-password spec and the
   public functions' help now use generic names (`example.json` profiles, `MyAppDb`,
   `DEV`/`TEST`/`STAGE`/`PROD` environments). `CompanyName` was removed from the manifest.
   Company-related information must never be added back to code or Markdown — see `CLAUDE.md`.

2. **Keep repository-only files out of the package — done.** Publish with `./Publish.ps1`, never
   `Publish-Module` on the repo folder directly: it stages an allow-list of module files (manifest,
   `Public/`, `Private/`, the example folders, README, CHANGELOG, LICENSE) and publishes from
   there. `PSGALLERY.md`, `CLAUDE.md`, `spec-kv-sql-login-passwords.md` and `Publish.ps1` itself
   stay in the repo only. A new file ships only once it's added to the list in `Publish.ps1`.

3. **Make the Roles folder configurable — done (0.10.0).** `RolesFolderPath` in the profile,
   resolved like `LoginsFolderPath`. Required by `Sync-SqlRoles` (no fallback to the module's own
   `Roles/`, which only holds examples); optional for `Get-SqlAccessReport`, which also takes
   `-RolesFolderPath`.

4. **Complete the manifest (`AzSqlAccessSync.psd1`).**
   - Done: `ProjectUri`, `LicenseUri` and `ReleaseNotes` point at the GitHub repo; `Copyright` is
     MIT with the module author as holder (matches `LICENSE`).
   - The repo is private for now, so those links 404 for gallery users — make it public before
     (or right after) the first publish.

5. **Check the module name is free:** `Find-Module AzSqlAccessSync` should return nothing.

### Should fix

6. **Use real `-WhatIf` support.** The public functions declare their own `[switch]$WhatIf` instead
   of `[CmdletBinding(SupportsShouldProcess)]` + `$PSCmdlet.ShouldProcess(...)`. Gallery users will
   expect standard `-WhatIf`/`-Confirm` behavior, and PSScriptAnalyzer flags the clash with the
   common parameter. The dry-run output format (`[WhatIf] Would ...` lines, `Planned` actions in the
   `-PassThru` summary) should be preserved.

7. **Stop installing modules at runtime.** `Private/Initialize-ImportExcelModule.ps1` and
   `Private/Initialize-PimGraphConnection.ps1` run `Install-Module -Force -AllowClobber` when
   ImportExcel / Microsoft.Graph.Authentication are missing. Declare them in the manifest
   (`PrivateData.PSData.ExternalModuleDependencies`) or throw with install instructions instead.
   They're soft dependencies on purpose (only needed for `-ExportToExcel` and PIM checks), so they
   should stay out of `RequiredModules`.

8. **Run PSScriptAnalyzer** (`Invoke-ScriptAnalyzer -Path . -Recurse`) and fix or explicitly
   suppress findings. `PSAvoidUsingWriteHost` will be common — the colored console output is
   intentional, so suppressing that rule is reasonable.

9. **Add Pester tests** for the parts that don't need a live SQL server:
   - loading and environment filtering of Logins/Roles JSON (including `${environment}`
     substitution in `Import-LoginConfig`)
   - role scoping in `Sync-SqlRoles`: roles without `databases` apply to every non-system database;
     `master` gets only roles that list it explicitly
   - `Private/Expand-SqlRoleChain.ps1` (nesting, cycle guard)

10. **Add a release pipeline** that runs PSScriptAnalyzer and Pester, then `Publish-Module` with the
    gallery API key stored as a secret. Optionally derive `ModuleVersion` from the release tag.

### Nice to have

- **Standalone-script code in `Public/*.ps1`.** The script-level `param()` blocks and the
  self-invoke block at the bottom of each file exist so the files can run as scripts outside the
  module. Decide whether that's still needed for a gallery module.
- **README for gallery users:** install instructions (`Install-Module AzSqlAccessSync`), required
  Azure/SQL permissions, and a quick start using the example profile/login/role files.

## Known gaps

All but the last were tracked in the original repo's `BACKLOG.md`, which is not being copied.
Carry over the ones still wanted (e.g. as issues in the new repo):

- Reuse SQL connections instead of one per query (`Private/Invoke-SqlAccessQuery.ps1`)
- Parallelize the per-login sync loop (`Public/Sync-SqlUserAccess.ps1`)
- `Import-LoginConfig` parses each JSON file twice (`Private/Import-LoginConfig.ps1`)
- Misconfigured role names fail silently — only `Write-Verbose` (`Private/Sync-SqlRoleMembership.ps1`)
- Logins can't be added to the custom server roles `Sync-SqlRoles` creates on VM/on-prem SQL Server
  (`Private/Sync-SqlRoleMembership.ps1`, `Private/Get-SqlAccessSnapshot.ps1`,
  `Private/Remove-SqlAccessDrift.ps1`)
- No retry/backoff for transient SQL or Graph failures (`Private/Invoke-SqlAccessQuery.ps1`,
  `Private/Test-EntraIdPrincipal.ps1`)
- No durable audit trail of changes made (`-PassThru` summary is not persisted anywhere)
- `-Document master` still treats roles without `databases` as documented in master, unlike the
  sync itself (`Public/Sync-SqlRoles.ps1`, `-Document` block)
