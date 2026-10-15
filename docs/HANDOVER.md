# Handover: aap-runner one-exe installer (milestones M2 to M6)

You are taking over engineering of `aap-runner`, a self-hosted GitHub Actions runner
host for Windows 11 + WSL2. Read this file fully, then `CLAUDE.md`, then
`docs/tray-launcher-plan.md` and `docs/tray-dashboard-design.md`, then the three
contract READMEs (`distro/README.md`, `supervisor/README.md`, `crates/tray/README.md`)
before you change anything.

## The goal in the owner's words

> One exe file which, when put in a folder and run for the first time, asks the user
> for elevated permissions for whatever it needs to do in Windows and WSL to deploy and
> set up runners. Properly check the system environment, check prerequisites, ask and
> offer the user to take care of all of them, deploy the runners, inform the user with
> progress all the while, ask if it needs something or if it fumbles, remediate and
> continue. Then start the tray.

## What exists today (v0.5.0, commit 1bc1e37 on main)

- `crates/tray`: Rust (egui, Rust 1.99 pinned in `rust-toolchain.toml`). The released
  exe is tray-only: status icon, single-view window (settings left, observability right,
  diagnostics swaps the right column), error panel, pause/resume, restart, "Retry now".
  It reads `C:\ProgramData\aap-runner\status.json` (schema 3) and writes only to
  `C:\ProgramData\aap-runner\inbox\{state,settings}.json`. It never runs `wsl.exe`.
- `supervisor/`: PowerShell 5.1 script run as SYSTEM by scheduled task
  `AAP-CRRR-Supervisor`. Reads the inbox, drives the WSL distro, writes status.json.
  Keep it in PowerShell: WSL cannot run under SYSTEM from a Windows service, so a Rust
  service is a dead end (already decided, do not revisit).
- `distro/`: bash. `bootstrap.sh` (3139 lines) builds the `aap-runner` WSL distro from a
  separate operator distro (`Ubuntu-24.04` with `jq` and `curl`). `manager.sh` runs the
  runner pool (up to 5 Docker containers, cgroup slice limits, IO cap).
- `installer/`: `install-host.ps1 -WorkDiskGiB 100 [-KeyPath]` (admin shell, needs the
  operator distro), `install-supervisor.ps1`, VHDX helpers.
- Identity (org, GitHub App id, installation id, labels) is hand-edited into
  `manager.conf` inside the distro. The App private key is copied by hand to
  `/etc/aap-runner/app.pem` (root 0400).

So a fresh PC gets a tray that says "Not installed" with everything greyed. Everything
underneath only works because the owner ran the scripts by hand.

## What you build, in this order, one PR each, each usable on its own

### M2: elevated helper inside the exe
- Same exe, new mode: `aap-runner-tray.exe --helper <verb> <request-id>`.
- The non-elevated tray writes a request file to `inbox\jobs\<id>.json`, then launches
  itself elevated via ShellExecute `runas` (one UAC prompt per action). The elevated
  helper validates the request (fixed verb set, no paths from the request are trusted),
  does the work, writes progress and the result to an admin-owned `jobs\<id>\` folder
  (status, log, exit code) that the tray polls and renders live.
- First verbs: `verify` (run the checks in `install-host.ps1 -DryRun` and the
  supervisor's own health checks, report pass/fail per item) and `repair` (reinstall the
  scheduled task, fix ACLs via `installer/lock-acl.ps1`, remount the work VHDX, restart
  the supervisor). Menu entries: "Verify install", "Repair install".
- The helper shells out to the existing PowerShell scripts; do not port them to Rust.
  Embed the scripts in the exe with `include_str!` and write them to the admin-owned
  folder before running, so the single exe stays the only artifact.

### M3: identity from the tray
- Settings panel gets: org slug, App id, installation id, runner group, labels, and a
  key file picker. The tray writes a `identity` request; the helper copies the key into
  the distro (`/etc/aap-runner/app.pem`, root 0400) and updates `manager.conf`, then
  the supervisor restarts the pool. Validate ids as integers, org as a GitHub slug.
- The key never touches the tray log, status.json, the inbox, or any output. The only
  copy outside the distro is the file the user picked.

### M4: first-run wizard
- On start with no install present, the exe opens the wizard instead of the tray:
  1. Prerequisite checks with a result per row: Windows 11 build, virtualization
     enabled, WSL2 installed and version, free disk on the install drive, admin
     available, network to github.com. Each failing row has a "Fix" button where a fix
     exists (`wsl --install --no-distribution`, enable features, reboot notice).
  2. Identity page (reuse M3).
  3. Sizing page (work disk GiB, runner count, reuse the existing settings panel).
  4. Install: one UAC prompt, live progress from the helper job folder, log tail, and
     on failure the error class plus the primary action from
     `docs/tray-dashboard-design.md` ("Retry", "Open log", "Copy diagnostics").
  5. Done: start the supervisor task, start the tray.
- The wizard must be resumable: closing it and reopening continues from the last
  completed step, recorded in `jobs\install\state.json`.

### M5: drop the operator-distro dependency (riskiest)
- `bootstrap.sh` today runs from a second Ubuntu distro. Replace that with: the helper
  downloads the Ubuntu 24.04 WSL rootfs tarball (pinned URL and sha256 in the exe),
  `wsl --import aap-runner <dir> <tar>`, then runs the bootstrap inside the new distro
  itself. `jq` and `curl` become part of the bootstrap. Do not use Ubuntu 26.04.
- Keep `bootstrap.sh --self-check` and `bash tests/run.sh` green on real Linux.

### M6: update and uninstall from the tray
- "Check for update": fetch the latest GitHub release of this repo, verify
  `SHA256SUMS` plus an ed25519 signature with a key compiled into the exe (no
  Authenticode, code signing is not available), download, swap the exe via the helper,
  re-register the HKCU Run entry. Never silent: always a prompt.
- "Uninstall": stop and delete the task, `wsl --unregister aap-runner`, delete the
  VHDX, remove `C:\ProgramData\aap-runner`, remove the Run entry. Confirm twice.

## Do not build

Rust Windows service, named pipes, MSIX, daily summary emails, more than 5 runners,
fleet management, silent auto-update, autologon, a heavy/light runner distinction.

## Hard rules

- Commits and PRs as `special-place-administrator
  <197073597+special-place-administrator@users.noreply.github.com>` only. No
  `Co-Authored-By`, no session trailers of any kind. Work on a branch, open a PR, never
  push to `main` directly, never force-push.
- CI stays on hosted runners (`.github/workflows/ci.yml`). Never add
  `pull_request_target` with a checkout. Never target the self-hosted group `aap-crrr`
  from this repo's workflows.
- Three suites stay green on every PR: `cargo fmt --all --check`,
  `cargo clippy --all-targets --locked -- -D warnings`, `cargo test --locked`;
  Pester 5 for `supervisor/` on both PowerShell 5.1 and pwsh 7; bash suite on WSL
  Ubuntu (`bash distro/manager.sh --self-check`, `bash distro/bootstrap.sh --self-check`,
  `bash tests/run.sh`, shellcheck 0.11 at `-S warning`).
- A contract change (status.json, inbox files, job files) updates the contract README
  and the other sides' tests in the same PR. Bump the schema number, keep reading the
  old one.
- Secrets: never print, log, copy or echo the App private key or any token. No tokens
  in the tray. If you need to confirm a key exists, report path and size only.
- The elevated helper trusts nothing from the non-elevated inbox except a fixed verb
  and an id matching `^[0-9a-f]{16}$`. All paths are derived by the helper from
  `C:\ProgramData\aap-runner`, never read from the request. Guard against junctions
  planted in `inbox\`.
- Do not touch the owner's live install. Do not run `wsl -d aap-runner`, do not start
  or stop the scheduled task, do not run `install-host.ps1` without `-DryRun`, do not
  launch the tray exe on this machine. Build and test only. The owner installs releases
  by hand after review.
- Keep the PowerShell supervisor. Keep egui. No new crates without a one-line reason in
  the PR description; prefer std and crates already in `Cargo.lock`.
- Small PRs, surgical diffs, no reformatting, no renames outside the task.

## How to verify each milestone

- M2: `cargo test` covers request parsing, id validation and job-folder state
  transitions. A Pester test runs `verify` against a fixture `ProgramData` tree.
  Manual proof is the owner's job; put exact steps in the PR description.
- M3: unit tests for validation; Pester test that the identity verb rewrites
  `manager.conf` in a fixture and refuses a key path outside the request's allowed
  picker result.
- M4: egui state-machine tests (step order, resume from `state.json`, failure page).
  Prerequisite checks are pure functions over injected inputs so they are testable
  without admin.
- M5: `bash tests/run.sh` on WSL plus a new test that bootstrap runs with no operator
  distro variables set.
- M6: signature verification tests with a test keypair; download code tested against a
  local file URL.

## Release

Tag `vX.Y.Z`, GitHub release with `aap-runner-tray.exe` and `SHA256SUMS`. The version
string shows in the tray menu as `AAP Runner vX.Y.Z (shortsha)`. Bump
`crates/tray/Cargo.toml` and the README in the same PR.

## Report back

End each PR description with: what works, what is not done, exact manual steps for the
owner to verify on the live machine, and any contract change. Ask the owner only when a
decision changes the product (not for implementation choices); otherwise decide, state
the assumption in the PR, and continue.
