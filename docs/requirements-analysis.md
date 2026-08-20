# Requirements Analysis: Windows 11 Debloat PowerShell Script

## Summary

The project is a Windows 11 administrative PowerShell utility that applies a defined, repeatable privacy and debloating configuration. Its core outcome is a system with selected non-essential packaged apps removed, telemetry-related services disabled, promotional UI settings suppressed, and unnecessary startup entries removed. Safety, clear feedback, and repeatable execution are first-class requirements.

## Scope

### In scope

- Enable System Restore on `C:` when necessary and ensure a `Pre-Debloat Restore Point` from within the previous 24 hours exists before any change.
- Remove an explicit allowlisted set of non-essential AppX packages for existing users and from the provisioning image.
- Configure diagnostic-data, consumer-feature, and Content Delivery Manager settings.
- Stop and disable `DiagTrack` and `dmwappushservice`.
- Remove an explicitly defined set of non-essential `Run` startup entries.
- Provide phase-level, color-coded console output and tolerate expected absent-state conditions.

### Out of scope or unspecified

- Removing traditional desktop applications, browser extensions, drivers, optional Windows features, or scheduled tasks.
- Restoring removed packages or reverting registry/service changes beyond creating a restore point.
- Supporting Windows 10, ARM-specific behaviour, offline Windows images, or non-administrator execution.
- Selecting startup entries automatically. The required definition of “non-essential” is not supplied.

## Requirement Interpretation

| Area | Implementation intent | Verification outcome |
| --- | --- | --- |
| Safety | Validate elevation before changing the machine; before all modifications, reuse the newest qualifying restore point from within the previous 24 hours or create one when none qualifies. | A restore point named `Pre-Debloat Restore Point` from within the previous 24 hours exists before app, registry, service, or startup changes start. |
| App removal | Maintain explicit package identifiers; remove installed packages and matching provisioned packages separately. | Targeted packages are absent for applicable users and do not appear in newly created profiles; protected core apps remain. |
| Privacy | Set the diagnostic-data policy and the named service states; set the required HKCU/HKLM advertisement settings. | Registry values match the selected policy and both services are stopped and disabled. |
| Startup | Use an explicit startup-entry list, with a conservative default. | Only named values are removed from the HKLM/HKCU `Run` keys. |
| Operational quality | Make each operation safe to repeat and emit a start/completion status for each phase. | A second run completes without fatal errors and reports each major phase. |

## Ambiguities and Recorded Decisions

1. **Package inventory:** Examples are not a complete, version-stable package list. Define exact package-family names and whether removal is mandatory or best-effort for every item.
2. **All-user semantics:** `Remove-AppxPackage -AllUsers` and provisioned package removal require different checks and can vary by Windows build. The expected behaviour for packages in use by another profile needs defining.
3. **Diagnostic data value:** A value of `0` does not represent the same effective level across all listed editions. Windows Home and Pro may enforce a higher minimum, so the script should report the configured value and warn when the OS does not honor it.
4. **HKCU scope:** HKCU modifications affect only the executing administrator's profile. If every existing profile is intended, the implementation needs an explicit per-profile registry-loading design; otherwise document this limitation.
5. **Startup entries:** Blanket cleanup of `Run` keys is unsafe. The requirements must name each removable value or provide a user-approved list.
6. **System Restore availability (resolved):** Restore point creation can fail because System Protection is unavailable, disabled by policy, or rate-limited. The accepted default is a hard stop; users may explicitly accept the risk with `-ContinueWithoutRestorePoint`. The newest matching restore point from within the previous 24 hours is reusable to accommodate the normal Windows frequency limit.
7. **PowerShell support:** AppX and restore cmdlets are most consistently available in Windows PowerShell 5.1. If PowerShell 7+ remains supported, the script should invoke compatible Windows PowerShell functionality or validate cmdlet availability first.

## Risks and Recommended Controls

| Risk | Control |
| --- | --- |
| Removing an app that a user needs | Use a reviewed explicit list, record each removal, and avoid wildcard package matching for frameworks and dependencies. |
| Restore point is unavailable | Reuse the newest matching point from within 24 hours or create one; stop before destructive changes unless the user explicitly opts in to continuing. Disclose that restoring a reused point can undo intervening unrelated changes. |
| Registry changes affect the wrong user scope | Clearly label HKCU as current-user only, or implement an intentional all-profile mechanism. |
| Broad startup cleanup breaks installed software | Delete only specified value names and export affected `Run` keys before modification. |
| Suppressed errors hide real failures | Suppress only known benign conditions; collect failures and show a final summary with non-zero exit status for critical failures. |
| Windows edition/build differences | Detect edition/build and report settings that could not be applied or are policy-limited. |

## Acceptance Criteria

- The script refuses to perform modifications without administrative elevation.
- Before any modification, it uses the newest `Pre-Debloat Restore Point` from within the previous 24 hours or attempts to enable System Restore on `C:` and create one; failure is clearly reported and follows the selected stop/continue policy.
- Its app-removal list is explicit, editable, and excludes Calculator, Notepad, Windows Terminal, AppX frameworks, and other declared protected packages.
- For every target package, the script attempts installed-package removal and provisioned-package removal independently, without failing when either is absent.
- `DiagTrack` and `dmwappushservice` are stopped when present and configured with startup type `Disabled`.
- Required HKLM/HKCU values are set to their specified values, with the effective scope identified in output or documentation.
- Only explicitly listed values are removed from HKLM/HKCU `Run` keys.
- Re-running the script reaches the same configuration without fatal errors.
- Console output marks the start and completion (or failure) of restore, app removal, privacy, UI suppression, and startup phases.
- A completion summary identifies successful operations, skipped absent items, warnings, and critical failures.

## Suggested Delivery Structure

1. Prerequisite and elevation validation.
2. Restore-point phase, with a fail-safe decision before proceeding.
3. Modular configuration arrays for protected packages, target packages, services, registry values, and startup value names.
4. Independent idempotent functions for app removal, service configuration, registry configuration, and startup cleanup.
5. Per-operation result collection and a final summary/exit code.

## Testing Strategy

- Test first in a disposable Windows 11 virtual machine with representative Home/Pro/Enterprise editions where available.
- Run once from a clean profile, then run again and confirm no fatal errors and no unexpected additional changes.
- Verify installed and provisioned AppX state before and after; create a new test profile to validate provisioning removal.
- Confirm service state and startup type after reboot.
- Validate the actual registry values and check which user profile receives HKCU settings.
- Test restore-point selection boundaries (name, age, malformed timestamps, and newest match) plus expected failures: no elevation, unavailable restore point, missing package, absent service, and locked/in-use package.
