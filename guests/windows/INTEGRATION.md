# Windows guest agent: integration requests (ledger item P14)

P14 owns only `guests/windows/**` and `tests/guests/windows/**`. Nothing below is wired into the image, the backend, the
broker or CI yet. How the agent works: [README.md](README.md).

## Contract defects

1. **The VM id "from the hypervisor" is switched off (guest-transport.md, Envelope; P10).** The only VM id a Windows
   guest can read from Hyper-V is the Data Exchange (KVP) intrinsic item `VirtualMachineId`
   (`HKLM\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters`). P10's `NewVm` turns Key-Value Pair Exchange off for every
   clone (supervisor/backends/windows/INTEGRATION.md, P10.0), so the agent refuses every command
   (`own vm id unavailable from the hypervisor`) and no clone ever becomes `ready`. The chair picks one:
   (a) P10 leaves Key-Value Pair Exchange on for runner clones (the host never reads the guest-to-host pool; the guest
   can write it, which changes nothing on the host), and P02.1 confirms the item appears before the first `probe`; or
   (b) a contract revision lets the agent take its VM id from the per-clone answer file P10 writes offline, read once at
   the first `probe` before the file is deleted (PowerShell Direct's `-VMId` addressing already rules out a command
   reaching another VM, so the check stays a guard against host bugs). Until then the agent fails closed.
2. **`work_folder` is `_work` (broker.md).** Hosted Windows jobs work in `D:\a\<repo>\<repo>` (`RUNNER_TEMP` `D:\a\_temp`);
   with `_work` relative to the runner root `D:\actions-runner` they work in `D:\actions-runner\_work\...`. Same disk,
   different path. For path parity the broker's profile table would send `work_folder` `D:\a` for the Windows profile
   (a constant of the profile, still never from the request); a broker.md revision (P08). The P17 runner-env workload
   checks that the folders exist, not their paths, so it does not catch this.
3. **The per-job cache budget has no source.** `Initialize-AapZcJob -BudgetBytes` must fit inside the scratch disk P10
   sizes (guests/cache/INTEGRATION.md, P10/P11 3), but neither contract names the value. The agent uses a fixed 10 GiB
   (`CacheBudgetBytes`, a `ponytail:` marker); the budget record (backend-lifecycle.md) should carry it.

## P21: image composition (overlays)

- `Import-Module guests\windows\AapGuestAgent.psm1; Install-AapGuestAgent -InstallDir "C:\Program Files\aap-guest"` as
  SYSTEM or an elevated administrator: the three agent files, the folder SYSTEM and Administrators only, inheritance off.
- Unpack the pinned actions-runner (P03-staged, hash-checked) to `C:\Program Files\aap-guest\runner` (so
  `runner\bin\Runner.Listener.exe` exists); no `config.cmd` run, no `.runner`, no `.credentials*` (the secret scan
  refuses them).
- `Install-AapZcCache ... -InstallDir "C:\Program Files\aap-guest\cache"` (guests/cache/INTEGRATION.md, P14 1).
- Turn off crash dumps for `Runner.Listener.exe` and `Runner.Worker.exe` (guest-transport.md, JIT secrecy rule); the
  mechanism (Windows Error Reporting `LocalDumps` per application, or excluded applications) is for the lab to confirm.
  Not done here.
- Record the agent overlay (the three files' SHA-256) in the generation's `overlays[]`.

## P10: Windows backend

- Contract defect 1 above (Key-Value Pair Exchange or the answer file).
- The agent answers `start_runner` within 40 s plus its PowerShell start; keep `start_runner`'s 60 s.
- After a failed bootstrap the agent answers `probe` with `error`/`failed`, final; the backend already abandons the VM.
- The scratch disk must be the only RAW disk at the first `probe` after Setup (no DVD drive holding `D:`).

## P02.1: what the lab must show for this agent

- The agent process started through PowerShell Direct can register and start the S4U task, and the task's process
  (launcher, Runner.Listener, cache daemons) outlives the session that started it.
- The task's environment is the job user's fresh logon environment (machine and user variables, `TEMP` in the profile),
  the token is elevated with the groups a hosted job shows (`whoami /all` against a hosted capture), its priority class
  is normal and no window opens.
- Runner.Listener of the pinned release takes `ACTIONS_RUNNER_INPUT_JITCONFIG` from its environment, removes it, runs one
  job and exits; with the synthetic marker, step 5's oracle finds it nowhere (event 4103/4104, transcription, files)
  outside the runner root.
- Windows Setup's cached answer files after specialize and OOBE: which files exist (and whether Setup already masked the
  password) at the first `probe`, and that none is left after it.
- `Get-Disk`/`Initialize-Disk`/`New-Partition`/`Format-Volume` on the scratch VHDX at first boot: time within one probe's
  30 s, and the volume reported as `Fixed` on a non-boot disk.
- The copy of the runner to `D:` within one probe (the next probe finishes an interrupted copy).

## Coordinator (CI)

Add `tests/guests/windows` to the Pester `Run.Path` of the Windows job in `.github/workflows/ci.yml` (both editions; the
suite imports `supervisor\backends\windows\AapWinBackend.psm1` for the host's reply check and creates one junction with
`mklink /J`, no elevation). `Invoke-AapGuestMutations.ps1` takes about 3 minutes per edition.
