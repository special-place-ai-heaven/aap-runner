# Capacity allocator: integration requests (ledger item P09)

`AapCapacity.psm1` implements the frozen allocator contract
([`parity/contracts/allocator.md`](../../parity/contracts/allocator.md), version 1). This file lists
what the consuming items have to do with it. P09 owns only `supervisor/capacity/**` and
`tests/capacity/**`; nothing below is wired into the supervisor, the providers, the distro or the
tray yet.

## The module in one page

- Windows PowerShell 5.1 and PowerShell 7.5 or later. PowerShell 6.0 to 7.4 turn ISO time
  strings into `DateTime` on read, so the module refuses to run there.
- Deploy `AapCapacity.psm1` and `allocator.schema.json` together. The schema is a byte copy of
  `parity/contracts/allocator.schema.json`; `tests/capacity/Validator.Tests.ps1` fails when they
  differ.
- Every exported function takes `-Root`, the capacity folder (production
  `C:\ProgramData\aap-runner\capacity`), and returns one object: `Ok`, `Status`, `Reason`,
  `Detail`, `TrustRelaxed`, plus its own fields.
- `Status` is one of these:
  - `ok`: the change was made.
  - `unchanged`: nothing to do, and nothing was written.
  - `ignored`: a late event for an older lease generation. It is logged and must not be acted on.
  - `refused`: a fixed `Reason` code, listed below. Nothing changed.
  - `error`: the operation could not run. Show status `error` and admit nothing.
- Each operation is one validated read-modify-write under `<Root>\allocator.lock`, which is opened
  with no sharing and waited for at most `-LockTimeoutSeconds` (30 by default). The state is
  written to `allocator.json.tmp` and swapped in with `File.Replace`. A document that fails the
  contract is never written.
- `<Root>\allocator.log` gets one line per state change and per ignored late event.
  `<Root>\unresolved.json` lists unknown VMs and folders; it is written only by reconcile.
- The folder is checked before every call, with the rules and SIDs of `install-supervisor.ps1`:
  - The leaf rule of `Test-AapAdminDescriptor`, also applied to inherit-only ACEs, because the
    files this module writes inherit them.
  - The ancestor rule of `Get-AapAncestorProblem`, up to the drive root.
  - No reparse point on the folder, above it, or at any file name the module uses.
  - A fixed local drive and a normalized absolute path.
- `-RelaxedTrustForTests` exists for tests only. It trusts the current user and skips the
  ancestor ACL check. Every other check stays. It prints a warning and writes a log line, and
  every result reports `TrustRelaxed`. Production code must never pass it.

| Function | Use |
|---|---|
| `Initialize-AapAllocator -HostInfo @{cpu_cores; mem_gib; disk_gib; io_mbps; control_distro_mem_gib} -Linux -Windows [-ShareMode -LinuxShare -WindowsShare -HostReservePercent -LinuxBackend]` | Creates the folder if missing and writes revision 1 once; never overwrites an existing state |
| `Get-AapAllocatorState` | The state plus `UsedSlots`, `FreeSlots`, `PoolCpus`, `PoolMemGib`, `UsedCpus`, `UsedMemGib`, and per profile `Count`, `Admitted`, `Live`, `EachCpus`, `EachMemGib`, `CapCpus`, `CapMemGib` |
| `Set-AapProfileCounts -Linux -Windows [-ShareMode -LinuxShare -WindowsShare -HostReservePercent -LinuxBackend -LinuxGeneration -WindowsGeneration]` | The two live controls and the shares; returns `Drained` and `Cancelled` |
| `Set-AapHostMeasurement -HostInfo` | A new host measurement, stored only if the live reservations still fit |
| `Request-AapReservation -Profile linux\|windows [-Cpus -MemGib -MemOverheadMib -DiskGib -IoMbps -ImageGeneration]` | Admission. Returns `Reservation`, `VmName`, `RunnerName` and `IdempotencyKey` |
| `Register-AapLegacySlots -ManagerStatus <status.json object> -ManagerVersion` or `-ManagerStopped` | Adopts the legacy pool, once |
| `Get-AapLegacyLimits [-JobCpus -JobMemoryGib]` | What `limits.conf` must say, and the size of the next legacy grant |
| `Update-AapHeartbeat -ReservationId -LeaseGeneration [-JobRunning]` | VM heartbeat |
| `Update-AapHeartbeat -ManagerStatus <status.json object>` or `-ManagerStopped` | Legacy heartbeats and legacy releases |
| `Set-AapSlotState -ReservationId -LeaseGeneration -State [-QuarantineKind -Reason -VmId]` | One edge of the state machine |
| `Complete-AapTeardown -ReservationId -LeaseGeneration -Proof` | The only way to free a slot |
| `Invoke-AapReconcile [-Inventory {..}] [-BrokerStatus {..}] [-LeaseWallClockHours 6]` | At start and every 10 minutes |
| `Test-AapAllocatorState -Path\|-Json\|-State` | The contract check; same verdicts and messages as `validate.py` |
| `Get-AapVmName -Profile -Slot -LeaseGeneration -ReservationId` | `aap-<w\|l>-<slot>-<generation>-<first 8 hex of the reservation id>` |

### Reason codes

| Status | Reason | Meaning |
|---|---|---|
| error | `untrusted_folder` | The folder, an ancestor or a state file failed the trust checks. `Detail` names it |
| error | `lock_timeout`, `lock_failed` | The lock was busy past the wait, or could not be opened |
| error | `not_initialized`, `invalid_state` | No state, or a state that fails the contract, is unreadable, or has a revision lower than one already applied |
| error | `failed` | Unexpected exception. `Detail` has the message |
| refused | `count` | The profile already has `count` admitted runners, or its count is 0 |
| refused | `ceiling` | All five slots hold live reservations, draining and quarantined ones included |
| refused | `share` | Over the per-runner share or the profile cap, VM memory overhead included |
| refused | `pool` | CPU over the pool; every live reservation counts |
| refused | `memory` | Memory over the pool, with the control VM paid first and VM overhead counted |
| refused | `disk` | Over the image-root disk budget |
| refused | `io` | Over the IO budget, or IO reserved while host IO is not measured |
| refused | `io_unmeasured` | A VM admission while `host.io_mbps` is 0 |
| refused | `legacy_not_adopted` | Any admission before `Register-AapLegacySlots` succeeded |
| refused | `generation` | A VM request not on the profile's active generation |
| refused | `unresolved_unknown` | An unknown VM or folder has no slot yet |
| refused | `resize_waits` | A heartbeat quarantine, or a VM still creating without a vm id, would have to leave admission. Retry next tick |
| refused | `pool_over_live` | New settings or a new host measurement cannot hold the live reservations |
| refused | `legacy_status_stale`, `legacy_over_count`, `legacy_over_share`, `legacy_over_pool` | Adoption refused. `Target` carries the most `limits.conf` may grant |
| refused | `illegal_edge`, `invalid_proof`, `not_found`, `bad_request` | The caller's request is wrong |
| ignored | `stale_generation` | The lease is not the slot's live one (a late `job_done`, an old heartbeat) |
| ignored | `quarantine_final`, `not_listening`, `legacy_status_stale` | A heartbeat that cannot apply |

## P12: supervisor, status v5, settings v3

1. **Import and deploy.** Import `capacity\AapCapacity.psm1` from the supervisor folder. P19
   copies `supervisor\capacity\` beside `aap-runner-supervisor.ps1`.
2. **Create the folder at install (P19), not on first use.** Use owner Administrators, full
   control for SYSTEM and Administrators, inheritance off, and no entry for the operator. The
   module accepts operator read, as the contract allows. But any unelevated process that can read
   `allocator.lock` can open it with no sharing and make every allocator call wait 30 s and
   fail. The tray reads `status.v5.json` instead.
3. **Start order.** Run these before the first admission:
   1. `Initialize-AapAllocator`, with the measured host. `cpu_cores` is logical CPUs.
      `mem_gib` is RAM. `disk_gib` is the image-root free space minus one `replacement_gib`, and
      minus `staging_gib` while a build runs. `io_mbps` is 0 until measured.
      `control_distro_mem_gib` is the control VM's resident memory.
   2. `Invoke-AapReconcile` with the providers' `-Inventory` and `-BrokerStatus`. This repairs a
      reservation a crashed predecessor persisted before the supervisor asks for another one,
      so it is never counted twice.
   3. `Register-AapLegacySlots`, until it reports adopted.
4. **Every tick while on.**
   - Call `Set-AapProfileCounts` with the applied settings (schema 3: `runner_count` as `-Linux`,
     `windows_runner_count`, `share_mode`, both shares, `host_reserve_percent`, `linux_backend`)
     and the catalog's active generations. It writes only on change.
   - On `resize_waits` or `pool_over_live`, keep the last applied settings and name the reason in
     the `status.v5.json` `detail`.
   - Then call `Update-AapHeartbeat -ManagerStatus` with the `status.json` object just written.
5. **Admission.** Request only while a profile has fewer admitted reservations than its count.
   - A legacy grant passes `-Cpus` and `-MemGib` from `Get-AapLegacyLimits`
     `NextSlotCpus`/`NextSlotMemGib`, computed with the settings' `job_cpus` and
     `job_memory_gib`.
   - A VM request passes the generation's measured budget, before the provider's `create`:
     `-MemOverheadMib` is `boot_mem_overhead_mib`, `-DiskGib` is `clone_peak_gib` plus
     `scratch_peak_gib`, and `-IoMbps` is the per-VM IO reservation.
6. **`limits.conf`.** Write `RunnerCount`, `JobCpus` and `JobMemoryGib` from
   `Get-AapLegacyLimits` when they differ.
   - `Stop = $true`: drain and stop the manager, and write no `limits.conf` with 0.
   - Once the unit is inactive, call `Update-AapHeartbeat -ManagerStopped`.
7. **Reconcile every 10 minutes.**
   - `Actions` with `destroy`: the provider destroys, then calls `Complete-AapTeardown`.
   - `Actions` with `replay`: the provider replays its journal.
   - `Flags`: busy runners past `lease_wall_clock_hours`. Show them in the `status.v5.json`
     `detail`.
8. **Status mapping.**
   - `status.v5.json` `capacity` comes from `Get-AapAllocatorState`: 5 slots, `UsedSlots`,
     `FreeSlots`, reserve, share mode and host.
   - `profiles` comes from `Profiles.*`: count, share, `EachCpus`/`EachMemGib` and
     `CapCpus`/`CapMemGib`.
   - `slots` comes from the live reservations, with `state` as the allocator lifecycle state.
   - Any `Status` of `error` makes the supervisor state `error`.
9. **Pause and off** need no new operation. Stop admitting, and move every `ready` or `busy`
   reservation to `draining` with `Set-AapSlotState`. A busy job keeps running.
10. **CI.** Add `tests/capacity` to the `pester` job's `Run.Path` in `.github/workflows/ci.yml`.
    That line is P00-owned, so the coordinator makes the change. The suite needs `python` on
    `PATH`; `windows-latest` has it. CI runs Windows PowerShell 5.1 only. Run pwsh 7.5 or later
    locally.

## P10 and P11: providers

1. **Admission first.** The reservation is persisted before `create`. Use `VmName` from the
   result for the VM and for the broker's runner name; `Get-AapVmName` derives the same name.
2. **Normal lifecycle.** Each step is one call, and every call carries the reservation id and its
   lease generation.
   1. After the guest `probe` answers ready: `Set-AapSlotState -State ready -VmId <guid>`. This
      records `vm_id` and `runner_name`.
   2. Job assigned: `-State busy`. A heartbeat with `-JobRunning` does the same.
   3. Job ended: `collecting`.
   4. Evidence collected: `deleting`.
   5. Teardown observed: `Complete-AapTeardown -Proof @{ kind = 'vm'; observed_at; vm_absent =
      $true; disks_absent = $true; vm_files_absent = $true; runner_deregistered = $true |
      'github-removed' | 'never_registered' }`.
3. **Create or boot failed before a VM id existed.** Call `Complete-AapTeardown` straight from
   `creating`, with `runner_deregistered = 'never_registered'`.
4. **Heartbeats.** Each validated guest `status` reply is
   `Update-AapHeartbeat -ReservationId -LeaseGeneration [-JobRunning]`. A heartbeat quarantine
   returns to `busy` or `ready`. `ignored`/`stale_generation` is a late reply: log it, never act
   on it.
5. **Quarantines.**
   - Hostile reply: `-State quarantined -QuarantineKind hostile_guest -Reason ...`, then destroy.
     The quarantine is final; heartbeats are ignored.
   - Teardown failed after the retries: from `deleting`, `-QuarantineKind teardown_failed`.
   - Unreadable journal: `-QuarantineKind crash`.
6. **Cancelled boot.** A resize may move a `creating` VM that has a `vm_id` to `deleting`. If a
   transition comes back `illegal_edge`, read the state and destroy.
7. **`-Inventory` for reconcile** returns `@{ vms = @(@{ name; vm_id; cpus; mem_gib }); folders
   = @('<reservation id>', ...); journaled = @('<reservation id>', ...) }`.
   - `vms` lists every VM named `^aap-(w|l)-[1-5]-`.
   - `folders` lists the ids that own a `clones\` or `scratch\` folder.
   - `journaled` lists the ids with any journal record.
8. **`-BrokerStatus`** is `param($Reservation)` and returns `@{ status = 'online' | 'offline' |
   'absent'; busy = $true | $false; job_ended = $true | $false }`, read with the broker's
   read-only `status_request`. Return `$null`, or throw, when the broker is unavailable.
   Destroy happens only for `offline` or `absent` with `busy = $false`, or `job_ended = $true`.
   Anything else keeps the slot held.

## P16: legacy adoption and the `AAP_RUNNER_COUNT` derivation

1. **Adoption** reads `status.json` as the supervisor writes it (schema 4): `sampled_at` at most
   90 s old, `state` idle, running or draining, `runner_count`, `job_cpus`, `job_memory_gib`, and
   `slots[].slot`/`state`.
   - Manager slot *i* becomes one `wsl-legacy` reservation of `ceil(job_cpus / n)` CPUs and
     `ceil(job_memory_gib / n)` GiB.
   - If the manager runs more slots than the Linux count, or slots larger than the Linux share,
     adoption is refused with `Target`. Write `Target` to `limits.conf`, wait for the manager to
     restart, and adopt again. No VM is admitted until then, so the legacy pool never runs five
     beside Windows.
2. **Grant before start.** A new legacy slot is `Request-AapReservation -Profile linux` (state
   `creating`) before `AAP_RUNNER_COUNT` grows. `Get-AapLegacyLimits` then returns the granted
   count, and the sums of their CPUs and memory, for `limits.conf`. Each grant is sized at the
   minimum of the setting and the Linux share, so the sums never exceed the minimum of the
   setting and the Linux cap.
3. **Release.** A legacy reservation that left admission (resize down, Linux 0) is released with
   a `legacy` proof by `Update-AapHeartbeat -ManagerStatus`, once the manager runs the granted
   configuration. That means idle or running, `runner_count` equal to the granted count, and
   applied totals no larger than the granted sums. `-ManagerStopped` does the same after the
   unit has stopped.
4. **Mapping.** Granted legacy reservations, oldest first, are manager slots 1..n. The manager
   restarts every slot on a limits change, so this is accounting, not identity. The totals are
   exact. **Request:** a per-slot id in the manager status would make the mapping exact.
5. **Retired slots.** A retired slot (`state` empty in `status.json`) gets no heartbeat. It is
   heartbeat-quarantined after 90 s, with capacity held, and returns when the manager restarts
   it.
6. **Resizing legacy slots.** A changed `job_cpus` or `job_memory_gib` sizes new grants only.
   Resizing existing legacy slots means draining and re-granting them (P12 and P16
   orchestration).

## P20: tray

- Read `status.v5.json` (P12), not `allocator.json`. If the tray ever reads `allocator.json`, it
  must:
  - open it shared for read, write and delete (Rust's default), so the supervisor's replace never
    fails;
  - reject `schema` other than 1;
  - ignore a lower `revision`;
  - never show free capacity from a missing or invalid file.
- Show per profile `Count`, `EachCpus`/`EachMemGib`, `CapCpus`/`CapMemGib` and the reserve. Flag
  `cleanup_uncertain` slots.

## Contract points decided here, for a ledger revision (coordinator)

1. **Legacy `busy -> ready`.** A legacy pool slot runs one ephemeral runner after another. The
   legacy heartbeat pass uses this extra edge when the manager reports the slot idle again.
   `Set-AapSlotState` does not offer it.
2. **`hostile_guest`.** Rule 10 forbids a quarantine kind on `deleting`. So the slot goes to
   `quarantined` (kind `hostile_guest`, final, never back to service), then to `deleting` or
   straight to `reconciled` with a proof.
3. **Wall clock.** `allocator.json` has no lease issue time, so the wall clock counts from
   `acquired_at`, which is earlier: the flag never comes later than the contract asks. Behaviour
   follows `allocator.md`: a busy runner is never destroyed. The contracts README's "wall clock +
   60 min" summary disagrees with that and should be corrected.
4. **Unknown folders.** A clone or scratch folder without a VM cannot hold a slot, because rule 9
   requires a `vm_id` past `creating`. It blocks admission (`unresolved.json`) until it is
   resolved. An unknown VM is placed in a free slot only when it fits the pool and its profile
   has an active generation to record. Otherwise it also blocks admission.
5. **Resize.** Leaving admission works like this:
   - Ready runners go first, then creating ones (to `deleting`), then busy ones (to `draining`,
     with the job still running).
   - In `even` mode a larger total count shrinks every runner's share. Every admitted runner over
     the new share drains, as the legacy manager does on any limits change.
   - A heartbeat quarantine cannot leave admission, so the resize waits (`resize_waits`).
6. **A larger reserve** that the live reservations cannot hold is refused (`pool_over_live`)
   until enough slots are reconciled, for example after a pause.
