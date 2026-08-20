# Functional & Technical Requirements Document

**Project Name:** Windows 11 Debloat PowerShell Script

**Repository Name:** `win11-debloater`

**Target Environment:** Windows 11 (Home, Pro, Enterprise)

---

## 1. System Overview

The `win11-debloater` project provides an automated, idempotent PowerShell script designed to streamline Windows 11 installations. The tool strips unnecessary pre-installed applications (bloatware), disables telemetry and background tracking services, suppresses OS-level advertisements and suggestions, and optimizes system startup performance.

---

## 2. Technical Prerequisites & Dependencies

* **Operating System:** Windows 11 (64-bit)
* **Execution Environment:** Windows PowerShell 5.1 or PowerShell 7+
* **Privileges:** Administrator privileges (`Run as Administrator`) required for system restore point creation, service management, and registry edits.
* **Execution Policy:** Execution policy set to permit script execution (e.g., `-ExecutionPolicy Bypass`).

---

## 3. Functional Requirements

### FR-1: System Safety & Rollback

* **FR-1.1:** The script MUST attempt to enable System Restore on drive `C:\` if it is disabled.
* **FR-1.2:** Before applying any system modifications, the script MUST ensure that a System Restore Point named `Pre-Debloat Restore Point` exists from within the previous 24 hours. It MUST create one when no qualifying restore point exists and MAY reuse the newest qualifying restore point to accommodate Windows restore-point frequency limits.

### FR-2: Bloatware App Removal

* **FR-2.1:** The script MUST target and remove specified built-in AppX packages for the current user and all user accounts (`-AllUsers`).
* **FR-2.2:** The script MUST remove provisioned AppX packages to prevent bloatware from reinstalling on newly created user profiles.
* **FR-2.3:** The target removal list MUST include non-essential Microsoft and third-party pre-installed packages (e.g., Bing News, Weather, Solitaire, Xbox apps, Spotify, Clipchamp, Disney) while preserving core OS apps (e.g., Windows Calculator, Notepad, Terminal).

### FR-3: Telemetry & Privacy Configuration

* **FR-3.1:** The script MUST set the Windows Diagnostic Data policy to `0` (Security/Disabled or Basic level depending on Windows edition) via Registry modifications in `HKLM`.
* **FR-3.2:** The script MUST stop and disable background tracking services, specifically `DiagTrack` (Connected User Experiences and Telemetry) and `dmwappushservice`.

### FR-4: UI Personalization & Ad Suppression

* **FR-4.1:** The script MUST disable Content Delivery Manager registry keys under `HKCU` that control Start Menu suggestions, targeted promotions, and notification ads.
* **FR-4.2:** The script MUST set policy flags under `HKLM` to disable Windows Consumer Features (auto-download of suggested apps).

### FR-5: Startup Optimization

* **FR-5.1:** The script MUST clean non-essential startup entries from system-wide (`HKLM`) and user-specific (`HKCU`) `Run` registry keys.

---

## 4. Non-Functional Requirements

* **Idempotency:** Executing the script multiple times sequentially MUST produce the same end-state without throwing fatal errors.
* **Error Handling:** Non-critical errors (e.g., attempting to remove a package that is not installed or stopping a non-existent service) MUST be handled gracefully using `-ErrorAction SilentlyContinue` to prevent script execution failure.
* **User Feedback:** The script MUST output color-coded progress messages to the console (`Write-Host`) indicating the start and completion of each major execution phase.
* **Maintainability:** Array variables containing target app packages, services, and registry keys MUST be modular and easy to modify by end users.

---

## 5. Risk Assessment & Mitigation

| Risk | Impact | Mitigation Strategy |
| --- | --- | --- |
| **Removal of required apps** | Medium | Maintain an explicit array of non-essential apps; avoid wildcard deletions on core dependencies (e.g., VCLibs, Frameworks). |
| **System instability from registry changes** | High | Ensure a named System Restore Point from within the previous 24 hours exists before executing modifications. Reusing one means a rollback can also undo unrelated changes made after that point, so disclose this scope to users. |
| **Execution blocked by policy** | Low | Document required execution parameters (`Set-ExecutionPolicy`) in the project README. |
