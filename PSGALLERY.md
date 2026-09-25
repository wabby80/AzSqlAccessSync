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

## Remaining work

### Blockers

1. **Organization-specific references — done.** README, CHANGELOG, the KV-password spec and the
   public functions' help now use generic names (`example.json` profiles, `MyAppDb`,
   `DEV`/`TEST`/`STAGE`/`PROD` environments). `CompanyName` was removed from the manifest.
   Company-related information must never be added back to code or Markdown — see `CLAUDE.md`.

2. **Delete files that aren't part of the module.**
   - `.claude/` (if present)
   - this file, once everything here is done (or keep it out of the published folder)
   - `spec-kv-sql-login-passwords.md` is kept (cleaned of internal names) as the design for a
     not-yet-implemented feature; move it to a `docs/` folder or an issue if it shouldn't ship

3. **Make the Roles folder configurable.** `Roles/` is read from a fixed path relative to the
   module (`Join-Path $PSScriptRoot '..\Roles'`) in:
   - `Public/Sync-SqlRoles.ps1` (`$rolesFolderPath`, also used by `-Document` to write its output)
   - `Private/Import-RoleConfig.ps1`

   After `Install-Module` that path is inside the module's install directory, so users would have
   to edit files there and `Update-Module` would overwrite them. Logins already avoid this via
   `LoginsFolderPath` in the environment profile (resolved relative to the profile file — see
   `Public/Get-SqlAccessReport.ps1`). Add a `RolesFolderPath` profile field handled the same way.
   Whether to keep falling back to the bundled `Roles/` when it's absent is an open decision.

   Done when: `Sync-SqlRoles`, `Get-SqlAccessReport` and `-Document` all read/write roles from the
   path in the profile, and the README documents the field.

4. **Complete the manifest (`AzSqlAccessSync.psd1`).**
   - `PrivateData.PSData.ProjectUri` — currently empty; set to the new repo URL
   - `PrivateData.PSData.LicenseUri` — missing; link the `LICENSE` file (MIT) in the new repo
   - `Copyright` — done: MIT, holder is the module author (matches `LICENSE`)
   - `ReleaseNotes` — point at the CHANGELOG URL in the new repo instead of "See CHANGELOG.md."

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
