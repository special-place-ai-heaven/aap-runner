# Windows guest agent: integration requests (ledger item P14)

P14 owns only `guests/windows/**` and `tests/guests/windows/**`. Nothing below is wired into the image, the backend, the
broker or CI yet. How the agent works: [README.md](README.md).

## Required before first real use: host-seeded identity record

The guest has no identity the host gave it, and three things rest on that. The chair fixes it with a coordinated
contract revision, not in P14: a per-clone identity record that P10 writes offline into the clone's answer file, which
the agent reads once at the first `probe` (before the bootstrap deletes the answer files) and then binds. Its fields:

- `vm_id`
- `reservation_id`
- `lease_generation`
- the expected scratch disk: its size and an identity the guest can see (which identity is a lab item)

Until that lands, and unchanged in this item's code:

1. The agent refuses every command, because it has no `vm_id`: it reads the KVP item P10 switches off and answers
   `refused` (`own vm id unavailable from the hypervisor`), so no clone becomes `ready` (contract defect 1).
2. Disk selection is a heuristic: `D:` as found, else the one disk besides the boot and system disk with at most one
   data partition (README, Bootstrap 4). Nothing ties it to the disk P10 attached, and its size is not checked.
3. The `reservation_id` and `lease_generation` binding is first writer: the agent binds the first ones it accepts into
   its state file, and whoever can delete that file (the job after `start_runner`, anyone holding the transport
   credential) can make the next command bind anew.

## Contract defects

1. **The VM id "from the hypervisor" is switched off (guest-transport.md, Envelope; P10).** The agent reads the Data
   Exchange (KVP) intrinsic item `VirtualMachineId` (`HKLM\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters`). P10's
   `NewVm` turns Key-Value Pair Exchange off for every clone (supervisor/backends/windows/INTEGRATION.md, P10.0), so the
   agent refuses every command (`own vm id unavailable from the hypervisor`) and no clone ever becomes `ready`. Open for
   the chair (not in this item): (a) KVP on for runner clones, which the security review advises against (it hands every
   job the host's fully qualified name and reopens the KVP pool P06 closed); (b) a contract revision that lets the agent
   take its VM id from a per-clone seed P10 writes offline, read at the first `probe` before any job; (c) the SMBIOS UUID
   (`Win32_ComputerSystemProduct.UUID`, the VM's `BIOSGUID`, which the host reads from `Msvm_VirtualSystemSettingData`;
   the lab confirms the byte order), with the envelope carrying that id. PowerShell Direct's `-VMId` addressing already
   rules out a command reaching another VM, so the check is a guard against host bugs. Until then the agent fails closed.
   The chair's direction: the host-seeded identity record above.
2. **`work_folder` is `_work` (broker.md).** Hosted Windows jobs work in `D:\a\<repo>\<repo>` (`RUNNER_TEMP` `D:\a\_temp`);
   with `_work` relative to the runner root `D:\actions-runner` they work in `D:\actions-runner\_work\...`. Same disk,
   different path. For path parity the broker's profile table would send `work_folder` `D:\a` for the Windows profile
   (a constant of the profile, still never from the request); a broker.md revision (P08). Not changed here. The P17
   runner-env workload checks that the folders exist, not their paths, so it does not catch this.
3. **The per-job cache budget has no source.** `Initialize-AapZcJob -BudgetBytes` must fit inside the scratch disk P10
   sizes (guests/cache/INTEGRATION.md, P10/P11 3), but neither contract names the value. The agent uses a fixed 10 GiB
   (`CacheBudgetBytes`, a `ponytail:` marker); the budget record (backend-lifecycle.md) should carry it.

## Host invariants (P10, P12, P22)

- After `start_runner` the job user (an elevated administrator) can rewrite the agent, its state, `launch.json` and the
  task, so every later reply is job-authored. Treat `status`, `collect` and `shutdown` replies as hints: the authority on
  the job is the broker's status of the runner. Never base VM reuse, cache promotion (a `collect` summary) or VM lifetime
  on a guest reply.
- Who may send commands is the transport's boundary: the per-clone PowerShell Direct credential. The agent binds the
  first `reservation_id` and `lease_generation` it accepts and refuses an `expires_at` more than 125 s ahead, but it does
  not authenticate a second sender; anyone with the credential can run anything in the guest anyway.

## P21: image composition (overlays)

- `Import-Module guests\windows\AapGuestAgent.psm1; Install-AapGuestAgent -InstallDir "C:\Program Files\aap-guest"` as
  SYSTEM or an elevated administrator: the three agent files, the folder SYSTEM and Administrators only, inheritance off.
- Unpack the pinned actions-runner (P03-staged, hash-checked) to `C:\Program Files\aap-guest\runner` (so
  `runner\bin\Runner.Listener.exe` exists); no `config.cmd` run, no `.runner`, no `.credentials*` (the secret scan
  refuses them).
- `Install-AapZcCache ... -InstallDir "C:\Program Files\aap-guest\cache"` (guests/cache/INTEGRATION.md, P14 1).
- A Runner.Listener dump taken before its job holds a live JIT config, and clone egress is open. Turn Windows Error
  Reporting dumps off (no `LocalDumps`, none for `Runner.Listener.exe` and `Runner.Worker.exe` in particular) and set WER
  consent to never send (guest-transport.md, JIT secrecy rule); the lab confirms both. Not done here.
- Record the agent overlay (the three files' SHA-256) in the generation's `overlays[]`.

## P10: Windows backend

- Contract defect 1 above.
- The agent answers `start_runner` within 40 s plus its PowerShell start; keep `start_runner`'s 60 s. A `start_runner`
  that answers `error` leaves a cancel mark: the launcher then starts no runner.
- After a failed bootstrap the agent answers `probe` with `error`/`failed`, final; the backend already abandons the VM.
  A probe that finds an earlier probe's bootstrap still running answers `booting`.
- The scratch disk P10 formats offline (`AapWinBackend.HyperV.psm1`, `NewDisk`: GPT, one NTFS partition, no drive letter)
  is the live path: Windows mounts it as `D:` and the agent uses it as found. That is safe only because the disk is new
  for every reservation; never attach a disk a job ran on. Keep `D:` free (no DVD drive). The agent cannot check the
  disk's size against the reservation's `scratch_gib` because no seed carries it yet (the identity record above).

## P02.1: what the lab must show for this agent

- The agent process started through PowerShell Direct can register and start the S4U task, and the task's process
  (launcher, Runner.Listener, cache daemons) outlives the session that started it.
- The task's environment is the job user's fresh logon environment (machine and user variables, `TEMP` in the profile),
  the token is elevated with the groups a hosted job shows (`whoami /all` against a hosted capture), its priority class
  is normal and no window opens; a job step's `Get-ExecutionPolicy -List` and `PSModulePath` match the hosted capture
  (`Process` `Undefined`).
- Runner.Listener of the pinned release takes `ACTIONS_RUNNER_INPUT_JITCONFIG` from its environment, removes it, runs one
  job and exits; with the synthetic marker, step 5's oracle finds it nowhere (event 4103/4104, transcription, files)
  outside the runner root.
- Windows Setup's cached answer files after specialize and OOBE: which files exist (and whether Setup already masked the
  password) at the first `probe`, and that none is left after it.
- P10's pre-formatted scratch disk appears as `D:` (`Fixed`, not the boot disk) at the first `probe`; whether the agent
  process survives the session closing when a probe times out (a surviving bootstrap holds `bootstrap.lock`, and later
  probes answer `booting` until it ends).
- The runner copy to `D:` within the 15-minute boot deadline (it resumes file by file across probes).

## Coordinator (CI)

Add `tests/guests/windows` to the Pester `Run.Path` of the Windows job in `.github/workflows/ci.yml` (both editions; the
suite imports `supervisor\backends\windows\AapWinBackend.psm1` for the host's reply check and creates junctions with
`mklink /J`, no elevation). `Invoke-AapGuestMutations.ps1` takes about 2 minutes per edition and fails on a surviving
mutant or on a tagged test that dies of anything but an assertion.
