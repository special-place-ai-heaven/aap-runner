# Plan: AAP Runner as one tray-driven product

Everything below was read on branch `cursor/runner-io-cap`. Nothing was modified and `wsl.exe` was not run.

## 0. What exists today, and the gaps that matter

- **Tray** (`tray/src/main.rs`, `state.rs`, `settings.rs`, `dialog.rs`). It runs without elevation. It writes only `inbox\state.json` and `inbox\settings.json` through `write_atomic` (a `.tmp` file, then rename). It polls `status.json` every 5 s and marks it stale after 180 s (`STALE_AFTER`). It has no install, update or uninstall path.
- **Supervisor** (`windows/aap-runner-supervisor.ps1`, 794 lines plus 1146 lines of Pester tests). It is an elevated logon task, `AAP-CRRR-Supervisor`, and not a service. The header explains why: SYSTEM cannot start WSL (`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`).
  - It owns On/Off (`Invoke-AapOn` and `Invoke-AapOff` drain and then terminate), health with backoff (`Invoke-AapHealth`), pause, and limits (`Invoke-AapLimitChange` writes `limits.conf` and runs `--check-limits`).
  - Gap: `Read-AapSettingsFile` only knows `runner_count`, `job_cpus`, `job_memory_gib` and `paused`. The manager already accepts `AAP_JOB_IO_PERCENT` and `AAP_POOL_SHARING` in `limits.conf`, but nothing on the Windows side can set them yet.
- **Installers** are two scripts the owner runs by hand from an admin shell.
  - `install-host.ps1` is built as `Get-AapInstallPlan(facts)` returning lines, actions and undo, then executed with `WOULD`/`DONE`. It is idempotent and re-run safe. It handles upgrades: when `staging.sha256` differs it re-stages.
  - `install-supervisor.ps1` sets the ProgramData ACL split, copies the supervisor into `C:\wsl\aap-runner-supervisor`, registers the task and adds the tray's Run value.
- **Hard prerequisite: an "operator distro".** `install-host.ps1 -OperatorDistro Ubuntu-24.04` runs `bootstrap.sh --preflight`, `--stage-downloads`, `--register-task` and `--format-work-disk` inside the owner's own Ubuntu. That distro needs `jq`, `curl` and `sha256sum`, plus interop and `/mnt/c`. This is the biggest obstacle to "hassle-free": a non-technical owner should not have to maintain a second Ubuntu.
- **Identity is hand-edited.** The App id and installation id are filled into `/etc/aap-runner/manager.conf` by hand after P0. `labels.sh` only allows the base label `crrr` or `fresh`. The org defaults to `special-place-ai-heaven` and the runner group `aap-crrr` is fixed in `manager.conf.example`. A standalone product must make these configurable.
- **Key handling.** `Install-AapKeyFromStdin` streams `-KeyPath` into `wsl -u root ... cat > /etc/aap-runner/app.pem`, checks mode `400:0`, then deletes the source file. Nothing is copied on the Windows side. Keep this.
- **Upgrading the manager kills jobs.** The README says the upgrade "stops and disables the manager", which is SIGTERM, and that removes every job container. An Update therefore has to drain first.

## 1. First-run wizard and how the tray reaches the elevated step

**Flow:**

1. The tray finds no install, meaning neither `inbox\` nor `config.json` exists. It opens the wizard, an egui window in its own process just like `--settings` today.
2. **Checks, all without elevation:** WSL version (`wsl --version` and `wsl --status`), virtualization firmware flag, the `AllowDiskMount` policy, free space on C:, `.wslconfig` (reusing `VmLimit::from_wslconfig` and the `networkingMode` rule), and Windows edition.
3. **Inputs:** org; App id; installation id; key file through the native Open dialog (`IFileOpenDialog`, filter `*.pem`); base and extra labels, checked with the same regex as `labels.sh`; runner count from 1 to 5; work-disk size, defaulting to 60 or 100 depending on detected RAM.
4. **Install:** one UAC prompt. The window then shows progress lines and keeps a "Show log" button.
5. **Start:** the wizard writes `{"desired":"on"}` and shows Verify (see section 4).

**Elevation mechanism (recommended).** `ShellExecuteExW` with the `runas` verb launches `C:\Program Files\AAP Runner\aap-runner.exe --helper <verb> <request-id>`. That path is a fixed, admin-only, signed binary. The request body is `inbox\req-<id>.json`, where `<id>` is `[0-9a-f]{16}`. The helper treats it as untrusted input, the same way `Read-AapJsonFile` treats inbox files today: one bounded read, a strict schema, and only fixed verbs (`install`, `repair`, `update`, `uninstall`, `set-identity`, `verify`). The helper writes progress to `C:\ProgramData\aap-runner\jobs\<id>.log` and `<id>.result.json`, both admin-owned and readable by the operator. The tray tails those files.

- **Rejected: a named pipe.** It needs a long-lived elevated server, a pipe ACL and lifetime handling, which is a new attack surface for no gain. Files are already the contract.
- **Rejected: a job file in the admin-only folder.** The non-elevated tray cannot write there. That is the whole point of the trust split.
- **Rejected: putting all arguments on the command line.** It brings quoting bugs with key paths that contain spaces, and a second parser next to the config schema. The command line carries only the verb and the id.

**Key file.** The request holds only the path. The elevated helper opens it and refuses a reparse point, more than 16 KiB, or anything that is not a `-----BEGIN ... PRIVATE KEY-----` block. It streams the bytes to the distro on stdin, exactly as `Install-AapKeyFromStdin` does now, and verifies `400:0`. A checkbox "Delete the original after install", ticked by default, replaces the silent delete that happens today. Nothing is written to temp, staging or ProgramData.

## 2. Settings from the tray

The split is by blast radius, so ordinary changes never need a UAC prompt.

- **Operator intent, no UAC:** `inbox\settings.json`. It gains two keys, `io_percent` (0 to 100) and `sharing` (`slice` or `fixed`), next to `runner_count` and `paused`. It also gains `"schema":2`.
  - The supervisor change is small: extend `Read-AapSettingsFile` and `Get-AapLimitsKey`, and let `Invoke-AapLimitChange` write the two additional keys into `limits.conf`. The manager already validates them.
  - The derived values `job_cpus` and `job_memory_gib` stay as they are.
- **Identity and security, UAC through the helper:** org, App id, installation id, key, labels, disk size. The tray stores these through `--helper set-identity`. The helper writes `config.json`, renders `manager.conf` from it with root and mode 0400, and restarts by draining.
- **Running now:** the existing `Snapshot::line` and `running_now` already show the repo, job and applied limits. Add the IO cap per slot and the sharing mode once status passes them through. The manager's `status.json` already has `job_io_mbps` and `sharing`, so the supervisor only needs to copy them across.
- **Update, Repair, Uninstall.** Each one goes Pause, then wait for `paused` (running jobs finish), then the helper verb, then resume.
  - **Repair** runs the idempotent install plan with the same facts. The `WOULD`-skip logic already exists.
  - **Uninstall** has two levels:
    - "Remove app": task, Run key, Program Files. This is today's `uninstall-supervisor.ps1`.
    - "Remove everything": unregister the distro, delete the VHDX and `C:\wsl`, and delete the ProgramData data folder. It needs a typed confirmation and runs `UNDO.md` in reverse.

## 3. Status and observability

- **Icons.** Keep the `mark.rs` badges and add none. Map one new state, `updating`, to the solid R.
- **Job display.** Already done: `Open job`, `valid_run_url`, and the repo short name.
- **Logs.** Keep "Open logs" for `logs\`, add `jobs\`, and add a "Copy diagnostics" item. That item zips `supervisor.log`, the last install log and `status.json` into the operator's Desktop, and never includes `manager.conf` or the key.
- **Toast** only on edge transitions into `error`, `stale`, or a failed Verify. A WinRT toast through the existing `windows` crate needs the `UI_Notifications` feature and no new dependency.
- **Daily summary.** Skip it (YAGNI). The manager has no job-count history. Add it once the owner asks, as a counter in `status.json`.

## 4. Robustness

- **Source of truth.** `C:\ProgramData\aap-runner\config.json` is admin-owned and written only by the helper. It holds `schema`, identity, the disk size and the release version. `inbox\settings.json` stays the only operator-writable intent.
  - `manager.conf` and `limits.conf` are derived files and are never edited by hand any more.
  - Repair re-renders them from `config.json`, so drift heals itself.
- **Crash-safe writes.** The tray already writes atomically and the supervisor already rewrites `status.json` that way. The helper uses the same `.tmp`, flush, `MoveFileEx(REPLACE_EXISTING|WRITE_THROUGH)` sequence. Inside the distro, `manager.conf` is written as `install -m0400` to a temp file, then `mv`.
- **Versioned contract.** Every file gets `"schema":N`.
  - The release manifest pins the versions of the exe, `supervisor.ps1` and the manager. The manager already prints `aap-runner-manager 2`.
  - The supervisor checks the manager's `--version` instead of grepping for `--undrain` (`Test-AapManagerFlag`). On a mismatch it reports `error` with the detail "run Repair".
  - The tray refuses a `status.json` schema newer than it knows, showing "update the app".
- **Upgrade path.**
  - The same verified exe re-runs the install plan.
  - The existing `staging.sha256` comparison decides whether distro files are re-staged.
  - The image is rebuilt only when `Dockerfile`, `ephemeral-entry.sh` or the runner pins change.
  - The previous release's exe is kept as `aap-runner.prev.exe` so a rollback is possible.
- **Verify.** The `--helper verify` verb runs `aap-runner-evidence`, which is non-destructive, plus `--check-limits` and `systemctl is-active`. It reports a PASS/FAIL list in the window.
  - An optional "test job" runs one `workflow_dispatch` of a tiny workflow on the base label. That needs Actions write and the App does not have it, so it stays a manual link for now. Verify proves the host, not GitHub.
- **Supervisor decision: keep PowerShell.**
  - **Against a Rust service:** a service cannot run WSL as SYSTEM. Running it as the user means storing the owner's password with the Service Control Manager, which is a new credential and breaks when the password changes. It also gains nothing, because WSL dies at logoff anyway.
  - **What a rewrite would buy:** one language. That is not worth porting 794 lines of tested logic and its 1146-line Pester suite.
  - **Ceiling:** the runner runs only while the owner is logged on. That is already documented in the README, and the wizard states it in plain words.
  - **When to revisit:** only if WSL ever supports SYSTEM, or if the owner accepts running the PC with autologon.

## 5. Packaging

- **Recommendation: one signed, self-installing exe, with no installer framework.**
  - `aap-runner.exe` is the tray, `--settings`, the wizard and `--helper`.
  - The helper copies the exe itself plus the embedded scripts (`include_bytes!`, compared against a compiled-in sha256 table before each run) into `C:\Program Files\AAP Runner\` and `C:\wsl\aap-runner-supervisor\`. Both are admin-only.
  - It also registers the tasks, the per-user Run value, and an Add/Remove Programs entry (the `HKLM\...\Uninstall\AAP Runner` key, which points at `--helper uninstall`).
- **Why not the alternatives:**
  - MSIX runs in a container and cannot cleanly register an elevated `InteractiveToken` task or set ACLs on `C:\wsl`.
  - WiX and cargo-dist both add a toolchain to reproduce what about 40 lines of helper code do.
  - Inno Setup is the fallback if the owner wants a classic setup wizard. If an MSI is ever needed for Intune or GPO, use `cargo-wix` then.
- **Signing.** Authenticode through Azure Trusted Signing, which is cheap and has no hardware token. Without a signature SmartScreen warns on every download. **This is a cost decision the owner has to make.**
- **Update channel.**
  - The tray checks GitHub Releases of the new repo once a day.
  - It accepts a release only when two checks pass: the Authenticode signer on the downloaded exe equals the running exe's signer, and the sha256 in a release manifest signed with ed25519 matches. The public key is compiled in.
  - Then it shows "Update available", and clicking it runs Pause, then the new exe's `--helper update`, then resume.
- **Repository layout.**

  ```
  Cargo.toml (workspace)
  crates/tray            UI, wizard, settings window (today's tray/src moves here)
  crates/helper          elevated verbs; a library linked into the one exe, kept separate for review
  crates/contract        serde types + schema versions for config/settings/status/request/result (shared, tested)
  supervisor/            aap-runner-supervisor.ps1 + task xml + Pester tests (unchanged logic)
  distro/                manager.sh, bootstrap.sh, labels.sh, evidence.sh, units, Dockerfile, ephemeral-entry.sh, staging.sha256
  installer/             install-host.ps1 (plan/facts/actions kept), lock-acl.ps1, create/mount vhdx
  tests/                 the existing --self-check suites + Pester + cargo test
  .github/workflows/     ci.yml runs on the runner itself (label of the dev box), release.yml signs + publishes
  ```

  CI on the runner itself covers `cargo test`, the bash `--self-check` suites and Pester under 5.1 and 7. Release signing runs on a GitHub-hosted Windows runner, so the signing key never sits on the runner it ships to.

## 6. Phased plan

Each milestone can ship on its own and is verified on Fresh.

| # | Milestone | Done when (on Fresh) |
|---|---|---|
| M1 | **Settings parity.** Add IO percent and sharing to `settings.json`, the supervisor parser, `limits.conf` and the dialog. Pass `job_io_mbps` and `sharing` through status. Add `schema` fields. | Changing IO% in the tray shows in `--check-limits` and in `status.json`. Pester and `cargo test` are green. |
| M2 | **Helper plus Repair/Verify.** One exe with `--helper`. Request and progress files. The `verify` and `repair` verbs wrap the existing `install-host.ps1` and `install-supervisor.ps1` (hashed and embedded). | The tray's Repair shows one UAC prompt and a live log, and leaves the system unchanged on an installed box. Verify lists PASS. |
| M3 | **Identity config.** `config.json`, `set-identity`, `manager.conf` rendered from config, and a configurable base label. This relaxes `labels.sh`'s `crrr`/`fresh` allowlist to the charset plus reserved-word check. | Changing the extra labels from the tray re-registers the runners with the new labels after a drain. |
| M4 | **Wizard and fresh install.** Prerequisite checks, file picker, install verb. The operator distro is still required and the wizard checks and explains it. | A clean Windows VM with Ubuntu-24.04 goes from download to a green Verify with one UAC prompt and no shell. |
| M5 | **Drop the operator distro.** Move preflight, downloads with sha256 (`C:\Windows\System32\curl.exe` plus `Get-FileHash`), the `.wslconfig` networking proof and task registration to Windows. Run `--format-work-disk` from `aap-runner` as root before lockdown. | Same as M4 on a VM with no Ubuntu installed. **This is the riskiest milestone** because `bootstrap.sh` is 3139 lines. |
| M6 | **Update and Uninstall.** Signed release, manifest check, drain-gated update, rollback copy, both uninstall levels. | Updating from vN to vN+1 while a job runs: the job finishes, the update applies, and the pool resumes. "Remove everything" leaves no task, distro or `C:\wsl`. |
| M7 | **Standalone repo.** Split along the layout above, keeping git history with `git filter-repo` on `ops/self-hosted-runner`. | Release CI publishes a signed exe, and Fresh updates itself from it. |

Do M1 to M3 inside the current repo. Split the repo only after the product works (M7). M7 can move earlier if the owner wants the new repo first, because it is mechanical.

## Risks

- **Runs only while logged on.** This is inherent to WSL, and the wizard must say so in plain words.
- **Elevated helper attack surface.** The request file is attacker-controlled by anything running as the operator. Mitigations: fixed verbs, strict schema, absolute System32 paths, and hash-checked scripts. The residual risk is the same as the supervisor's documented one: UAC is not a security boundary.
- **Update during long jobs.** The drain can take up to 6 h (`DrainTimeoutSeconds`). Show "Update waiting for job X" rather than forcing it.
- **Unproven parts.**
  - IO cap and slice mode under sysbox are not verified live (README WARNING blocks). Verify should report "configured, not proven" until a job is measured.
  - M5 rewrites the most delicate install steps, the work disk and the networking proof.
- **Code-signing cost and SmartScreen reputation.** Decide before M6.

## Do not build

- A Rust Windows service, a named-pipe IPC, or MSIX.
- A daily summary, a job history database, or a web dashboard.
- More than 3 runners in the UI, even though the manager allows 4.
- Multi-host fleet management from one tray.
- Auto-generating the GitHub App through the manifest flow. App creation stays a one-time manual step with a linked checklist, because it needs org-owner clicks anyway.
- Silent auto-update without a click.
- Storing the owner's Windows password for autologon or a service.

## Owner decisions (2026-10-14 evening)

1. One exe. First run asks for elevation itself and handles all prerequisites on any Windows 11 (check environment, offer to enable WSL / install the distro / fix .wslconfig, then deploy the runners). The wizard milestone (M4) and the "no operator distro" milestone (M5) move up: the product must not depend on a second Ubuntu.
2. No code signing (not possible). Self-verification instead: compiled-in ed25519 public key, signed release manifest with sha256 of the exe, embedded scripts hash-checked before every elevated run, `aap-runner.prev.exe` rollback. README states SmartScreen will warn once on first run and how to proceed.
3. New repo https://github.com/special-place-ai-heaven/aap-runner (public, MIT) created; clone at C:\AI_STUFF\PROGRAMMING\aap-runner. M7 (repo split with history) runs FIRST. The stale AAP branch cursor/runner-autostart is deleted after the migration.
