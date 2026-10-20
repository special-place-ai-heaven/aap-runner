# Windows VM backend: integration requests (ledger item P10)

P10 owns only `supervisor/backends/windows/**` and `tests/backends/windows/**`. Nothing below is wired into the
supervisor, the installer, the guest image, the network or CI yet. How the backend works: [README.md](README.md).

## P12: supervisor

1. **Load.** `Import-Module <supervisor>\backends\windows\AapWinBackend.psm1`, then
   `AapWinBackend.HyperV.psm1` beside it. The backend imports `..\..\capacity\AapCapacity.psm1` and
   `..\..\broker\aap-broker.psm1` itself, so those folders keep their places.
2. **Build the context once per supervisor start:**

   ```powershell
   $B = New-AapWinBackend -Provider (New-AapWinHyperVProvider) -Network <P10.0 module's Attach/Detach/Verify>
   ```

   Every path defaults to production (`C:\ProgramData\aap-runner\capacity`, `...\capacity\journal`,
   `...\capacity\storage.json`). It throws on a missing or invalid storage document (`AAP_StorageMissing`,
   `AAP_StorageInvalid`) or an untrusted journal folder (`AAP_JournalUntrusted`): show the code in `status.v5.json` and
   keep the VM profiles off. It creates a missing journal folder admin-only. Never pass `-RelaxedTrustForTests`.
   Without `-Network` every create fails closed (`AAP_NetworkUnavailable`).
3. **Storage status.** `Get-AapWinStorageProblem -Backend $B` returns `<tier>: <problem>` lines (empty = trusted) for
   `base_root`, `clone_root` and `scratch_root`. Run it at start and each tick; a non-empty list is tier state
   `untrusted` (or `missing`) and `volumes = @()` for `Set-AapHostMeasurement`. The staging tier is P03's.
4. **Every tick**, for every live reservation with `profile` `windows` and `backend` `hyperv-vm`
   (`(Get-AapAllocatorState).State.reservations`):

   ```powershell
   $res = Invoke-AapWinStep -Backend $B -Reservation $r -BaseSha256 <approved-images.json pin of $r.image_generation>
   ```

   One step at a time; a step makes at most one guest command plus one broker call, except that create, a job's end and
   a hostile reply run on through destroy. A step can still take minutes: create re-hashes the base (a 130 GB file on
   the USB volume) and destroy waits up to 3 x 5 s. Run Windows steps so that a slow one never delays heartbeats of the
   others past 30 s (one runspace per reservation, or the slow ops first).
   - `Action`: `created`, `booted`, `probing`, `ready`, `running`, `listening`, `busy`, `recovered`, `destroyed`,
     `waiting`, `held`. `Code` is a fixed word (`hostile_guest` codes, `teardown_failed`, `release_pending`,
     `release_uncertain`, `journal_unreadable`, `timeout`, `no_reply`, ...): put it in `detail` as is.
   - `Summary` (collect only) is guest-authored text, bounded and printable: never a status reason, never logged
     unfiltered.
   - Any exception is a provider failure: log its `AAP_<Reason>`, retry next tick.
   - `-BaseSha256` comes from the admin-only pin (`approved-images.json`, P24), never from the catalog under
     `base_root`. Create refuses without it (`AAP_BaseUnpinned`).
5. **Admission** stays P12's (`Request-AapReservation` with the generation's measured budget). Request no Windows VM
   while `Get-AapWinStorageProblem` is non-empty or the P10.0 module is missing.
6. **Reconcile** every 10 minutes and at start:

   ```powershell
   Invoke-AapReconcile -Root <capacity> -Inventory { Get-AapWinInventory -Backend $B } `
       -BrokerStatus { param($r) Get-AapWinBrokerStatus -Backend $B -Reservation $r }
   ```

   `Get-AapWinInventory` lists every VM named `aap-(w|l)-<slot>-...` on the host (Linux ones too: one host, one list),
   every folder under `clone_root` and `scratch_root` and every journal. It throws on a listing error or on any entry in a
   tier root that is not a reservation folder. When P11 lands, use one inventory for both profiles: union the folder and
   journal lists, keep one VM list. `destroy` and `replay` actions need no call of their own: the next
   `Invoke-AapWinStep` of that reservation carries them out.
7. **Wall clock.** The backend never destroys for the wall clock. The allocator's reconcile `Flags` name the slots past
   `lease_wall_clock_hours`; show them.
8. **Pause, off, resize**: move `ready`/`busy` to `draining` with `Set-AapSlotState`; the backend stops idle runners and
   waits for busy ones.
9. **Unknown VMs.** An `unknown_vm` quarantine is held by the backend. Removing such a VM needs a journal entry that
   names it (allocator.md, Reconcile); how the owner approves that is a P12/P20 decision (not built here).

## P19: installer and helper

- Deploy `supervisor\backends\windows\` beside `capacity\` and `broker\`, Administrators/SYSTEM-only like the supervisor
  script: an operator who can write the module or `psdirect-call.ps1` gets code execution in the elevated supervisor.
- The journal folder may be created by the installer (admin-only, protected DACL, SYSTEM and Administrators only); the
  backend creates it the same way when missing.
- `clone_root` and `scratch_root` must be admin-only (no ACE for any other SID, not even read): the per-clone credential
  sits in the clone disk until first boot.

## P10.0: the guest network module

The interface the backend calls, each op one hashtable `@{ VmId; VmName; Profile = 'windows' }`:

| Op | Contract |
|---|---|
| `Attach` | Connect the VM to the profile's guest network: exactly the adapters it needs, each on the internal switch `aap-guests-win` with DHCP guard and router guard on and MAC spoofing off, port ACLs as guest-transport.md lists. Throw on any failure. The VM comes from `NewVm` with no adapter |
| `Verify` | Return a list of problems (strings), empty when the VM's network is exactly as Attach made it, ACLs included. Never throw for a problem found; throw only when it cannot look |
| `Detach` | Remove whatever Attach made for this VM beyond the VM itself (per-guest switch, NAT entries, rules). Idempotent: absent is done. Called at every destroy attempt, after `Remove-VM` |

The backend also checks, from the VM's own settings, that every adapter is on `aap-guests-win` of type Internal with
DHCP guard and router guard on and MAC spoofing off; Enhanced session and the Guest Service Interface stay off per VM
(`NewVm`), Key-Value Pair Exchange too.

## Every child with redirected stdin (P12, P14)

- Write stdin only through `StandardInput.BaseStream`, and start the process under a preamble-free
  `[Console]::InputEncoding` (`New-Object Text.UTF8Encoding($false)`), restored in `finally`, tolerating a host without
  a console. Windows PowerShell 5.1 otherwise writes the encoding's preamble at `Process.Start`, and under code page
  65001 the child reads `EF BB BF` before the first byte. `Start-AapWinProcess` in `AapWinBackend.psm1` and the remote
  script in `psdirect-call.ps1` do this; `Transport.Tests.ps1` checks the bytes under the current code page, 65001 and 850.
- Secret bytes (the JIT config, the guest password) never appear in a function parameter that is logged, an argument
  list or script text: they go to the child's stdin only.

## P14: the guest agent

- Entry point `C:\Program Files\aap-guest\agent.ps1` (Administrators-only), started by the fixed remote script in
  `psdirect-call.ps1` as `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <it>`; its stdin is
  the envelope line, a newline, then exactly `payload_bytes` bytes; its stdout is one reply line (the first line is
  taken).
- The job user is `runneradmin`, local administrator, created by the per-clone answer file
  (`Windows\Panther\unattend.xml`, which the agent deletes at first boot with every other bootstrap file).
- The refusals of guest-transport.md, Envelope, are the agent's: own `vm_id` from the hypervisor, first
  `lease_generation`, `seq` exactly previous + 1, fresh `nonce`, one-shot classes once, not expired.
- Replies the backend accepts per command: `probe` `booting` or `ready`; `deliver_registration` `registered` or
  `listening`; `start_runner` `listening` or `busy`; `status` `listening`, `busy`, `job_done` or `failed`; `collect` any
  but `booting`, `ready` and `registered`. `collect`'s reply is the job summary (`runner_exit_code`, `diag`).

## P02.1: what the lab must show for this backend

- PowerShell Direct through `psdirect-call.ps1` with the job object's limits: a real session fits in 512 MiB and the CPU
  cap; remote `Write-Host`, prompts and stream floods end in a non-zero exit or an extra stdout byte (both hostile), never
  in a hang; `[Console]::SetOut([IO.TextWriter]::Null)` keeps remote host output off stdout.
- Hyper-V attaches `os.avhdx` to a read-only `base.vhdx` (P06's ACL) and mounts a clone disk attached to an Off VM for
  the answer-file rewrite after a crash.
- How close a full scratch VHDX comes to its maximum size (the backend leaves 64 MiB under `scratch_gib`).
- That a VM created with `New-VM -Path <clone>\<id>` and the smart paging and snapshot paths there leaves no file outside
  the clone folder (the backend checks the paths Hyper-V reports).

## Coordinator and CI

- Add `tests/backends/windows` to the Pester `Run.Path` in `.github/workflows/ci.yml` (P00-owned line). The suite needs
  `python` on `PATH` and creates junctions with `mklink /J` (no elevation needed).
- The crash tests start hidden child processes (about 20 per run); the whole suite takes about 3 minutes per host.

## Contract requests and open questions

1. **Lease id in the journal.** The `op` record has no lease field, and an `intent` record has no result, so the lease id
   rides in the `ready` record's `done` detail (`probe ready; lease l-<32 hex>`), written before the lease call. A
   contract revision could add `lease_id` (nullable) to `op` records.
2. **Teardown of a reservation that never got a VM.** `validate.py` requires a `vm_id` on every op after create, so such a
   cleanup is journaled as `create` `failed` (`abandoned before a VM existed`), not as `destroy`.
3. **No guest channel after a supervisor restart.** guest-transport.md keeps the Windows credential in supervisor memory
   only, so a restart loses every guest channel: running jobs finish under the broker's status (heartbeat quarantine,
   then destroy once the runner is offline or absent and idle), clones not yet running a job are destroyed. Persisting
   the credential (DPAPI, admin-only, per reservation, like the Linux private key) would keep heartbeats and the clone
   cap check across restarts; that is a contract change.
4. **Hard VM lifetime cap (broker INTEGRATION.md, F4).** A guest that holds its runner credential can keep GitHub
   reporting it online and busy, so a heartbeat-quarantined slot may never be freed. The contract says the wall clock
   only flags; the owner decision on a hard cap is still open. Nothing here destroys for time.
5. **Clone cap without a guest channel.** The clone folder is sampled only while this process can heartbeat the guest.
   After a restart a runaway job is bounded by the volume floor only.
6. **Base re-hash cost.** Every create re-hashes the whole base (130-140 GB planned). Measured in P02.1/P22 it may need a
   cheaper pinned check (for example a hash cached against the file's identity and the read-only ACL).
