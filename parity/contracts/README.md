# Shared parity contracts (ledger item P02, revised by P02.2 and P09.x)

Frozen interfaces for the GitHub-runner parity work. The architecture they implement is
[docs/parity/ARCHITECTURE.md](../../docs/parity/ARCHITECTURE.md). A change to a contract is a
ledger revision first, then a new contract version; no worker edits these files opportunistically.

```
python -B -I parity/contracts/validate.py                       # every fixture, exit 0 = all hold
python -B -I parity/contracts/validate.py <contract> <file>...  # validate real documents
```

`validate.py` is standard library only. It implements the draft 2020-12 keywords these schemas
use, refuses any other keyword, and adds each contract's cross-field rules. Each invalid fixture
names the error it must produce, so it cannot pass for the wrong reason.

## Index

| Contract | Version | Files | Writer | Readers | Status |
|---|---|---|---|---|---|
| [Allocator](allocator.md) | 2 (text revised by P09.x) | `allocator.schema.json` | P09 | P10, P11, P12, P16, P20, P22 | DECIDED; hard VM lifetime cap decided (owner Q4), conformance P09 follow-up, P10.6, P11.3 |
| [Backend lifecycle](backend-lifecycle.md) | 3 (records `schema` 2) | `backend-lifecycle.schema.json` | P10, P11; storage document P19 | P09, P12, P19, P20, P22, P25 | DECIDED; budgets and cap enforcement measured later (P02.1, P06, P07); hard VM lifetime cap decided (owner Q4), conformance P10.6 and P11.3 |
| [Broker](broker.md) | 1 | `broker.schema.json` | P08 | P10, P11, P14, P15, P16, P26 | DECIDED; JIT runner behaviour CANDIDATE (D2) |
| [Guest transport](guest-transport.md) | 2 | `guest-transport.schema.json` | P10/P11 host (the identity record is their offline write at create), P14/P15 guest | P22, P26 | envelope and identity record DECIDED; mechanisms CANDIDATE (D2) |
| [Image catalog](image-catalog.md) | 2 (P02.5: additive overlay field) | `image-catalog.schema.json` | P21, P25 | P06, P07, P10, P11, P12, P19, P20, P24 | DECIDED |
| [Cache qualification](cache-qualification.md) | 2 | `cache-qualification.schema.json` | P04 | P13, P14, P15, P16, P20, P22, P24 | DECIDED |
| [Status and settings](status-settings.md) | settings 3 and 4, status 5 (revision 4); tray-local 1 | `settings-v3`, `settings-v4`, `status-v5`, `tray-windows-choice` schemas | P12, P20 | P19, P22 | DECIDED; landed in P12 (supervisor reads 3 and writes `status.v5.json`; tray reads it and writes 3); window controls P20; settings 4 and the per-slot cap object (hard VM lifetime cap, owner Q4) are contract only until the P12 and P20 follow-ups land |
| [VM deadline record and lifetime clock](allocator.md#host-power-off-backstop-decided-owner-decision-q4-review-b1-to-b9) | 1 each (P09.x) | `vm-cap-notes.schema.json`, `lifetime-clock.schema.json` | P10.6 and P11.3 (Notes record), P12.3 (supervisor clock), P10.7 (watchdog clock) | P10.7, P12.3, P02.1 | DECIDED (owner Q4 review); contract only until P10.6, P10.7, P11.3, P12.3 and P19.1 land |
| [Evidence and cleanup](evidence-cleanup.md) | evidence 2, receipt 1 | `evidence-bundle`, `cleanup-receipt` schemas | P05, P00 | every item, P24, P26, P28 | DECIDED |
| [Host network module](host-network-module.md) | 2 | `host-network-module.schema.json`; shared check `supervisor/network/AapHostNetworkCheck.psm1`; shared fake `tests/common/AapHostNetworkFake.psm1` | P10.0 | P06, P07, P10, P11, P12, P19 | interface, switches and the host-neighbour poisoning protection (permanent host neighbour entry per guest address + static MAC of the module's range; protects host-to-guest delivery only, clone-to-clone residuals listed; Verify reads the entry back) DECIDED (coordinator 2026-10-21, control adopted 2026-10-22); mechanism and the control's lab proof CANDIDATE (D2); consumers not yet conformant |

## Decided

1. One five-slot allocator in the hidden supervisor counts every backend, including the legacy
   WSL pool, which is adopted before any VM registers.
2. Two live controls (Linux 0-5, Windows 0-5, sum 1-5), a never-allocated host reserve (floor 10 %),
   `even` shares by default and `per_profile` shares on request (the owner's 30/60/10 example).
3. Reservations persist before boot or registration, carry the slot's lease generation, and are
   freed only by observed teardown. Admission checks shares at admission; pool, disk and IO budgets
   count every live reservation, so draining overhang delays the other profile. Three missed
   heartbeats quarantine with capacity held; a heartbeat restores the slot; destroy waits until
   GitHub reports the runner offline and not busy, or the job ends, or the VM's hard lifetime cap
   is reached (item 13); hostile guests go straight to deletion from any state, a heartbeat quarantine
   included. Neither a resize nor a new host measurement evicts admitted work.
4. Provider interface, idempotency keys, intent/outcome journal, crash recovery, the disk layout per
   storage tier, and measured-only budgets with enforced per-tier caps.
5. App key stays root-only in the control distro; the broker is a fixed-path one-shot root program
   called over `wsl.exe` stdin/stdout with bounded, attacker-choice-free requests; one JIT config
   per lease id; release by lease id at every teardown; runner status for quarantine decisions;
   replay, skew, per-slot stale-generation and outstanding-lease refusals; secret-free audit.
6. JIT config instead of registration tokens for VM guests, delivered in memory and consumed as
   `ACTIONS_RUNNER_INPUT_JITCONFIG`, never argv or a file.
7. The fixed management command set, wire framing (capped child process for PowerShell Direct,
   agent entrypoints, stdin/stdout only, vsock port 5222, hardened ssh), echo/sequence/nonce replay
   rules (host sequence rises on every send; the agent accepts any strictly greater number), hostile-reply handling, and the guest network enforcement shape.
7a. JIT secrecy: no copy outside the runner's root and processes; destroy is the control; `reset`
   forbidden; the runner starts as `Runner.Listener` directly.
8. Immutable catalog generations tied to the P01 baselines, one active per profile, one retained
   rollback, quarantine is final.
9. zccache 1.15.6 only, per-pair qualification, direct compilation otherwise, no sccache.
10. `status.json` stays schema 4; schema 5 is `status.v5.json`; settings schemas 3 and 4 are written only
    when advertised; unknown future schemas are rejected safely on both sides.
11. Evidence record and both receipt shapes, with independent verifiers and observed absence;
    waivers are listed in the record (revision 2).
12. Storage tiers (owner, 2026-10-20): configurable `base_root`, `clone_root`, `scratch_root` and an
    optional `staging_root`, set only through the elevated helper and never from the inbox; each
    passes the ProgramData trust checks at install, at every supervisor start and before every
    `create`; no defaults and no hard-coded drive letters; per-volume disk admission with a
    free-space floor (backend-lifecycle.md, allocator.md).
13. Per-clone guest identity record (owner, 2026-10-21; guest-transport revision 2): the host writes
    it OFFLINE at `create` — Windows into the answer file, Linux into the cloud-init seed; the guest
    binds `vm_id`/`reservation_id`/`lease_generation` and the expected scratch disk from it once, at
    the first `probe`. Host-to-guest KVP stays off (the P06 security review), and the SMBIOS
    UUID is not the carrier. No host-identifying data rides the record. Fail-closed
    (guest-transport.md, Per-clone identity record): a missing or malformed record (or two) and a
    scratch disk that does not match end the first `probe`; a command that differs from the record
    is `refused`; a different or second record before cleanup, or any record after cleanup, is never
    bound and ends the clone. The wire cannot tell a revision-1 agent from a revision-2 one, so
    admission verifies the agent: only a generation whose catalog entry certifies revision 2 or
    later, the rollback generation included, is admitted (guest-transport.md, Admission;
    image-catalog.md, rule 8).
14. VM lifetime enforcement (owner Q4): `vm_lifetime_cap_hours` is 1..6, default/ceiling 6, from immutable
    `acquired_at`. Latch in memory, issue bounded hypervisor power-off, then persist and perform verified teardown;
    only teardown proof frees capacity. All due VMs get concurrent enforcement; one other blocking call at a time.
    The supervisor completes its initial E1 attempt within 90 s. The independent watchdog fairly services all five
    VMs with durable E1/E2 progress within 300 s, including enumeration, observation and persistence. **Only observed
    Off means terminated**; failed stopping mechanisms yield an unresolved `cap_breach`, held capacity, blocked starts
    and continued enforcement, never a claim that network detachment stopped execution. Boot-bound high-water time
    preserves restart age; reboot/clock-loss safety decisions have explicit triggers and unknown/below-cap elapsed
    evidence. Journal ordering uses consistently nondecreasing high-water timestamps, not raw wall-clock order.
    A mandatory installer gate resolves every pre-existing VM to valid Notes or verified absence before activation.
    Details and failure-injection requirements: allocator.md L1-L10/B1-B9 and backend-lifecycle.md.

## Candidate pending D2 lab proof

The transport lab proof is a **single-owner ledger child, P02.1**, which gates P10/P11 fan-out
(the coordinator adds it to the ledger). Its prerequisites are gate D2 plus a **lab GitHub App**
and a **test org and repository**, so the lab never uses the production App, key or org. Plan:
[guest-transport.md](guest-transport.md#lab-proof-plan-p021-executed-for-p08-p10-p11).

1. PowerShell Direct as the Windows management channel, including credential bootstrap by the
   offline unattend answer file, and safe handling of hostile deserialized output.
2. SSH over a Hyper-V socket for Ubuntu with KVP host-key pinning (fallback: per-clone isolated switch).
3. Guest network isolation (internet only; no host, WSL distro, LAN or other guests): one
   internal switch per profile with Windows NAT, host firewall rules and per-adapter ACLs, or one
   internal switch per guest (a private switch has no host adapter and is not viable).
4. End-to-end JIT runner behaviour on the pinned runner release: environment input consumed and
   masked, one job, registration gone afterwards, unused runner deletion, no copy left in the guest.
5. (Removed by the security review: `reset` is forbidden, so there is nothing to prove.)
6. Measured disk, memory and IO budgets per generation and tier, and the enforcement of the clone
   and scratch caps (lab plan step 8).
7. hvsocket service registration through the existing elevated helper (P19).

## Resolved 2026-10-19

The five open decisions, settled by the owner and coordinator on 2026-10-19:

1. **Runner labels and group for the VM profiles.** Windows
   `self-hosted,Windows,X64,aap-win25-vs2026`; Ubuntu `self-hosted,Linux,X64,aap-ubuntu-24.04`;
   runner group `aap-crrr` for both. The legacy WSL pool keeps its current labels
   (`self-hosted,linux,<base>[,extras]`). These live in the broker's root-only profile table
   (broker.md); requests can never choose them.
2. **Image root volume** (superseded on 2026-10-20 by the storage tiers, see below).
   `<image_root>` was `D:\aap-runner\images` (about 2.3 TB free on 2026-10-19), flat:
   `base\<profile>\<generation>\` (one folder per generation, never moves),
   `clones\<reservation>\`, `scratch\<reservation>\`, plus `catalog.json`. Rollback is catalog
   state only (coordinator decision on the architecture review). The
   budget is measured in P06 and stored as `budget` records before any admission.
3. **Control distro uptime.** The distro and its keep-alive run whenever Linux + Windows >= 1,
   because the broker that holds the App key lives there. "No `wsl.exe` call while Off" holds only
   when both counts are 0 or desired is off. Recorded in status-settings.md, Supervisor states.
4. **Host reserve floor.** 10 % is confirmed as the minimum (schemas already enforce it).
5. **Gate D2.** The owner provides a Windows Server 2025 Evaluation ISO (180-day) for the golden
   image. The evaluation build is sufficient to prove parity; a licensed production image is a
   later owner decision. The rearm or rebuild cycle before evaluation expiry is defined in P06
   (build) and P25 (operations). The lab host is this machine (Hyper-V enabled). The compute and
   storage budget was approved by the owner on 2026-10-20 (Resolved 2026-10-20, item 4).

## Resolved 2026-10-20

1. **Storage tiers** (owner). Nothing for the Windows runner lives on the NVMe system volume. The
   image area is no longer one hard-coded root: the installer and the owner choose `base_root`,
   `clone_root`, `scratch_root` and optionally `staging_root`, which may share one volume or use
   several ([backend-lifecycle.md, Storage tiers](backend-lifecycle.md#storage-tiers-decided-owner-2026-10-20)).
   The owner enlarged the dedicated volume `E:` (`winrunner`) from 195 GB to 585.9 GB on
   2026-10-20; it is a partition of the USB disk that also holds the owner's data volume `D:`.
   Partitions and volumes are the owner's: no item creates, resizes, formats, relabels or
   re-letters one, or changes a volume root's ACL.
2. **Sizing evidence.** The hosted Windows image at job start uses 127,436,206,080 bytes of a
   160 GB `C:` with 33,031,553,024 free, and 3.2 GB of a 161 GB `D:` (run 39303666617), on 4 vCPU
   and 16 GiB. Planning estimate: 130-140 GB per base generation plus build headroom, 20-50 GB per
   running job, plus one rollback generation (backend-lifecycle.md, Sizing evidence).
3. **Volume-root ACLs** (owner). On 2026-10-20 the owner locked `E:\` to Administrators (lab
   preparation, 01:04). `D:\` is the owner's data volume, still grants Everyone full control and
   is never used. The earlier open decision on volume-root ACLs is closed as not needed: `E:` is
   locked by the owner, and the proposed relaxation of the ancestor rule is dropped. Whether a root
   on `E:` passes is shown by running the check (P19, P02.1), not by this record.
4. **Lab budget** (owner, gate D2), approved on 2026-10-20: lab data only under `E:\aap-runner\`;
   base generation at most 200 GB; rollback generation at most 200 GB; clone plus scratch at most
   60 GB per runner; at least 15 % of the 585.9 GB volume kept free; build VM with 4 vCPU and
   10 GiB static RAM, one at a time. Measuring the real budgets stays lab step 8
   (guest-transport.md) and P06/P07.
5. **Floor value**: `volume_floor_gib` is 15 % of the volume, 88 GiB for `E:` (of 585.9). The
   contract minimum stays 10.
6. **Where the roots are configured** (coordinator): in the admin-only storage document
   `C:\ProgramData\aap-runner\capacity\storage.json`, which only the elevated helper writes, and
   never in settings schema 3, because the inbox is user-writable
   ([status-settings.md](status-settings.md#storage-in-status-schema-5-draft-revision-2)). The tray
   shows them from `status.v5.json` and offers a helper verb to change them (P19, P20).

## Open decisions (2026-10-20)

1. **A count increase in `even` mode drains every runner** (owner). Each runner's share is
   `floor(pool / (linux + windows))`, so raising either count (for example Linux 2 to 3 beside
   Windows 1) lowers every share, and every admitted runner drains: the legacy manager gets a stop
   request while the Linux count stays above 0, so each increase is a full legacy stop and start
   ([allocator.md, Resize and host measurement](allocator.md#resize-and-host-measurement-decided-p09-review-2026-10-20)).
   `per_profile` mode confines a count change to its own profile. The owner decides whether that
   is acceptable in `even` mode or whether the default share mode changes.
2. **Heartbeat quarantine for `draining` and `collecting`** (coordinator, P09 security review).
   Today three missed heartbeats quarantine only `ready` and `busy`. A VM in `draining` or
   `collecting` that stops answering would otherwise wait for its job or teardown without a
   quarantine ([allocator.md, Provider rules](allocator.md#provider-rules-for-p10-and-p11-decided-p09-security-review-2026-10-20)).
3. **Persist the cap's monotonic anchor?** Closed by the review of the hard cap: the supervisor persists a high-water
   mark of true time every tick with a boot id and a counter (`lifetime-clock.json`), so a clock step followed by a
   restart no longer shortens a VM's age and the decision is latched
   ([allocator.md, L7](allocator.md#hard-vm-lifetime-cap-decided-owner-decision-q4-2026-10-22)). What cannot be
   recovered (a reboot with the clock stepped back, a lost record) is handled conservatively and bounded by the VM's
   uptime and the backstop.
4. **Where may a VM profile run without the cap?** (P09.x, for the owner). A supervisor older than the first one
   that enforces the cap flags only, so a downgrade or a half-finished install would run VM jobs with no cap. The
   installer (P19) could refuse to enable a VM profile on such a supervisor; the contract does not require it yet.
5. **A backstop independent of allocator state?** Required, not optional: the host watchdog uses validated VM Notes
   and its own durable progress, never allocator/journal/backend modules. By B5's bound it observes Off or explicitly
   reports an unresolved breach; failed host stopping mechanisms are not described as bounded termination.
6. **Should a lowered cap reach running VMs at once?** (P09.x, for the owner). `allocator.json` has no field for a
   per-reservation cap (its schema is frozen by the capacity module's byte copy), so a lowered
   `vm_lifetime_cap_hours` applies to every live VM at the next tick, and `inbox\settings.json` is user-writable.
   Applying it only to later reservations needs one allocator field; the contract chose the simpler rule (the
   operator account can already stop the pool and read the broker's key).

## Security review (2026-10-19) items carried by other owners

- **P10.0 guest network module** (new ledger item, coordinator adds it): the one shared guest
  network module for P10 and P11, implementing the enforcement shape in guest-transport.md. Its
  interface, call order, declaration, read-back, switches and failure codes are frozen in
  [host-network-module.md](host-network-module.md) (2026-10-21), and its read-back has one
  implementation for every consumer, `supervisor/network/AapHostNetworkCheck.psm1`.
- **P02.1**: lab cases added for crafted CLIXML, remote host-UI calls, stream floods, a
  guest-replaced endpoint, IPv6 and host-port reachability, ARP/DHCP/RA spoofing, WSL mirrored
  mode, host PowerShell 4103/4104 and transcription, and a stolen runner credential; plus the
  framed-hvsocket comparison for Windows; plus the sequence cases: lose the reply after the agent
  accepted the request and the next probe is accepted, and a gapped `seq` is accepted.
- **P16 todo**: correct the `distro/README.md` threat-model row: any process of the operator
  account can reach the distro as root and read `app.pem` (WSL session per SID, no elevation), so
  the broker's rules are integrity controls, not access control.
- **P19**: the installer creates and locks the configured storage roots and writes the storage
  document, registers the hvsocket service GUID, the guest firewall rules and the core-scheduler
  check through the existing helper; a helper verb changes the roots.
- **P21/P24/P25**: image scan targets, hash pins outside every storage root, owner live-activation
  record (D5), runner overlay rebuild inside GitHub's support window.

## Revision follow-ups (P02.2) carried by other owners

- **P03**: the staging root is the storage document's staging tier (`staging_root`, or
  `<base_root>\staging`), held to the same checks; the README example under
  `D:\aap-runner\images` is superseded.
- **P04.1** (done 2026-10-21): the Linux `debug-pdb` (`-g`) rows for every compiler version (8
  more rows, Linux matrix revision 2), and `retention.md` requirement 4 now follows rule 6's job
  trust class.
- **P05.1**: write waivers into the evidence record's `waivers` field and stop appending them to
  `command`; until then `parity-report.json` and `verdict.json` stay authoritative. Nit: the
  harness's `re.match(...$)` checks for workload ids and SHAs accept one trailing newline (Python
  `$`); `validate.py` now rejects such values in the records.
- **P07, P11**: match the hosted Ubuntu kernel, `read_ahead_kb` and mount options, or justify each
  difference with a reviewed allowlist entry (image-catalog.md, Acceptance input).
- **P09**: `allocator.json` schema 2 (per-volume disk budgets, reservation `clone_gib` and
  `scratch_gib`) and the P09 review points: the legacy `busy` to `ready` loop, hostile replies from
  a quarantine, the wall clock from `acquired_at` (flag-only then, a hard cap since P09.x), no eviction (clamped host,
  `resize_waits`, `pool_over_live`), the `even` mode drain, and unknown folders blocking admission.
- **P10, P11**: the inventory callback returns a complete list or throws (allocator.md, Reconcile).
- **P13**: cache roots per repository plus the job's trust class (cache-qualification.md rule 6);
  the GitHub-side source of event, ref and head repository is the job record matched by
  `runner_id` and `runner_group_id`, bound before attach, through a per-lookup installation token
  with `actions`, `contents` and `metadata` read only (owner decision: the App gains `actions: read`
  and `contents: read`); `workflow_dispatch` is untrusted, and untrusted jobs get a private
  per-job root only.
- **P19, P20**: the storage document, its helper verb and the tray's storage view.

## Revision follow-ups (P09.x, owner decision Q4) carried by other owners

The hard VM lifetime cap is a contract until these land: the supervisor, the providers and the tray still implement
revision 3 (the wall clock flags and never destroys), and no watchdog exists. Until the items below are done and the lab
proof is given (the owner's), no VM profile serves a public repository (owner decision Q4). The ids are proposals; the
ledger is the orchestrator's. Every failure-injection test below runs against fakes whose calls can hang, fail or never
return, on both PowerShell hosts.

- **P10.6 (Windows backend) and P11.3 (Linux backend)**, each in its provider and its suite: write the VM's deadline
  record before the first start and start only after the read-back and a healthy backstop (allocator.md, B1 and B7;
  backend-lifecycle.md); evaluate the cap at every point of L3 and run every call bounded and isolated, due power-offs
  concurrently dispatched, teardown calls held to the nearest other deadline; one order, latch, power off, persist,
  teardown (L4); durable escalation E1/E2 and explicit cap-breach handling (L5); fencing so no start follows the decision,
  no interrupted create/boot resurrects a capped VM and teardown proof stays valid (L6); high-water `power_off_utc`
  (backend-lifecycle.md); drop the drain-keep flag (`DrainKeepHours`, `drain_overdue`). Tests: the boundary (one second
  before the deadline and at it); five concurrent E1 attempts completed within 90 s, with termination asserted only
  when Off is observed; a hung power-off while another deadline passes; A due now/B one second later with release
  hanging; a guest that ignores shutdown (no guest call after the decision); a guest call that blocks until its timeout
  while a deadline arrives; a runner GitHub keeping `online` or `busy`; a heartbeat quarantine; a drained VM waiting
  for its release; a stuck `creating` with and without a `vm_id`; a power-off that fails and repeats with the slot held
  and the ladder climbing; a release answering `retry`; a journal or allocator write that fails, or a process that dies
  after the power-off (the VM stays off, nothing restarts it, the slot is reclaimed); a crash between the power-off
  and the persisted latch; a replayed `create` or `boot` for a capped reservation; a Notes write whose read-back differs
  (no start); a stale watchdog record (no start); a clock stepped back and forward; `unknown_vm` and legacy slots
  untouched; no slot reuse before the teardown proof; every record through `validate.py`.
- **P10.7 (watchdog)**: implement B3-B7's bounded complete enumeration, one concurrent stage for every due VM, durable
  escalation progress/recovery and the 300 s Off-or-explicit-breach outcome. Test five VMs with hanging E1/E2, a process
  killed during E1 and after its progress write, restart resuming E2, no starvation, bounded inventory/observation/write
  failures, a still-running VM after E2 (cap_breach, not termination), and an Off observation clearing only execution
  uncertainty, never teardown proof. Test supervisor down/off/error, allocator loss/lock, unknown VM with valid Notes,
  foreign/invalid/copied Notes refused, explicit reboot/clock-unavailable evidence, and no deletion or slot release.
  The complete run is at most 50 s: 10 s inventory/identity/clock, 30 s concurrent stage, 5 s observation, 5 s persistence.
- **P12.3 (new, supervisor)**: `lifetime-clock.json` every tick with boot id and counter, restart recovery (L7),
  conservative handling of a reboot or missing/invalid clock record (cap existing running VMs, never restart an off VM),
  the latched decisions, the capacity pass at every evaluation point including before status writes, the start gate and
  `backstop_down:`, settings schema 4 and the schema 3 key at 1..6 (refuse 7..72 whole, `vm_cap_refused`), advertise 4,
  the per-slot `vm_lifetime_cap` object (not for an `unknown_vm`), `clock_step`, `supervisor/README.md` and its tests
  (one fixture is still named `future-schema-4`).
- **P09.1 (new, allocator module `supervisor/capacity`)**: the direct edge to `deleting` from every live state that has
  a `vm_id` (L4, step 3b; a `creating` reservation without one stays `creating`) and its test;
  `Invoke-AapReconcile` stops flagging; its `LeaseWallClockHours` range becomes 1..6. Its schema copy stays
  byte-identical: this revision did not change `allocator.schema.json`.
- **P19.1 (new, installer)**: register/remove the watchdog task and admin-only folders (B8). Before enabling a VM profile,
  reconcile every pre-existing managed VM: require a valid B1 Notes record bound to the actual GUID/name, or ordinary
  verified teardown and observed absence. Any unrecorded, unmatched or unresolved VM blocks activation and remains held
  until resolved; install the watchdog and require a fresh B7 heartbeat before any VM starts. This is mandatory, not an
  owner option. Test that missing/damaged Notes or unresolved teardown blocks activation and verified absence clears the gate.
- **P20.1 (new, tray)**: write schema 4 once advertised, carry the schema 3 key across unchanged, never rewrite a
  stored cap above 6, show `vm_cap_refused:`, `backstop_down:` and a fired slot's `reason`; `LEASE_HOURS` becomes 1..=6
  (`crates/tray/src/settings.rs`); `crates/tray/README.md`. The installed tray is not changed without the owner's word.
- **P02.1 (lab, gated on the owner)**: a guest that ignores `shutdown` and keeps its runner credential, at a 1 h cap and
  at 6 h, with the supervisor healthy and with the supervisor and the allocator killed (the watchdog's bound), a hung
  power-off, and two VMs due one second apart; record the measured lateness; confirm the counter and boot id across a
  supervisor restart, a host sleep, a wall-clock step and a reboot; inject clock-record loss while VMs are running and
  confirm both enforcers fail closed as the contract requires.

## Findings recorded while freezing

- `supervisor/README.md` and the supervisor still limit `windows_runner_count` to 0..4 (schema 2,
  correct while no Windows backend exists); settings schema 3 widens both counts to 0..5.
- The current tray treats `status.json` schema 5 as an error, hence the separate `status.v5.json`.
- The P01 cleanup receipt's `reviewed_head` was not a full SHA on 2026-10-19; the coordinator
  corrected it, and all six receipts in the evidence store pass on 2026-10-20.
- Before revision 2, `validate.py` used Python's `$`, which also matches before a final newline, so
  a value with one trailing newline passed its pattern. Patterns now anchor at the end of input,
  as in ECMA-262.
- Schema patterns are matched as full strings: every pattern outside a `not` starts with `^`, ends
  with `$` (end of input) and has no top-level alternation, so none relies on search semantics;
  `validate.py` lints this. A pattern under `not` is a deliberate "contains" check, such as a `..`
  component.
- Ports of these patterns anchor with `\z` (.NET), and PowerShell uses `-cmatch`, because `-match`
  ignores case and lowercase-only patterns (`volume_guid`, `definition_id`, reservation ids) would
  accept uppercase.

## Revision log

| Date | Item | Contract | Version | Change |
|---|---|---|---|---|
| 2026-10-19 | P02 | all | 1 (settings 3, status 5 drafts) | frozen |
| 2026-10-20 | P02.2 | cache-qualification | 2 | `maxItems` 64 to 256; Linux `debug-pdb` (`-g`) rows for every compiler version; rule 6 namespace is the repository plus the job trust class. Matrices keep `schema` 1 |
| 2026-10-20 | P02.2 | evidence-cleanup | evidence 2, receipt 1 | optional bounded `waivers`; records keep `schema` 1 |
| 2026-10-20 | P02.2 | backend-lifecycle | 2 | storage tiers and the `storage` document; tier-relative disk paths; budget caps `clone_gib_max` and `scratch_gib_max`; records `schema` 2 |
| 2026-10-20 | P02.2 | allocator | 2 | per-volume disk admission: `host.volumes`, reservation `clone_gib` and `scratch_gib`; `allocator.json` schema 2 |
| 2026-10-20 | P02.2 review | allocator, backend-lifecycle, status-settings, cache-qualification | unchanged | P09 contract points (allocator.md, Resize and host measurement, Reconcile); a VM reservation reserves clone disk; `COM0`/`LPT0` and trailing-space device names; drive letters and volume GUIDs one to one; cache trust class from the job's event, ref and head repository; admin-only capacity folder and clone/scratch roots; data-folder, `COM0` and path-shape root fixtures; waivers only for the record's own workload; fixed storage `detail` codes; schema patterns linted for `_ecma` and full-string anchoring |
| 2026-10-20 | P02.2 | image-catalog | 2 | catalog at `<base_root>\catalog.json`, artifact paths relative to `base_root`, catalog `schema` 2; P07/P11 acceptance input from P05 |
| 2026-10-20 | P02.2 | status-settings | status 5 draft, revision 2 | `storage` in `status.v5.json`; settings schema 3 unchanged, no paths |
| 2026-10-20 | P02.2 | guest-transport | 1 (text only) | lab storage preconditions and the budget step (step 8); envelope unchanged |
| 2026-10-20 | P02.2 | validate.py | - | `$` is the end of input; documents bounded to 256 KiB (a 256-row matrix is about 90 KB) |
| 2026-10-20 | P13 security review | cache-qualification | 2 (text only) | rule 6: `workflow_dispatch` untrusted; tag push trusted only when `head_sha` is reachable from the default branch; class from the job record matched by `runner_id` and `runner_group_id` (owner decision: App gains `actions: read`, `contents: read`); untrusted jobs get a private per-job root only; namespace key adds the zccache version; host never mounts a namespace disk after a guest has had it. No schema change |
| 2026-10-20 | coord-ci-wiring | evidence-cleanup | receipt 1 | cleanup-receipt `item` also accepts `coord-<slug>` (lowercase letters, digits, hyphens) for coordinator jobs; fixtures `coord-manual-shape` and `coord-item-uppercase`; `schema` stays 1 |
| 2026-10-20 | P10 review | guest-transport | 1 (text only) | sequence rule: the host raises `seq` on every send and never reuses one; the agent accepts any `seq` strictly greater than the last accepted (gaps allowed), refuses less than or equal as a replay, and echoes nonce and `seq`; a timeout never changes the counter rules, so a lost reply cannot cause a false `refused`; lab cases added. Replaces exact previous + 1, which wedged the channel after one failed or lost probe |
| 2026-10-21 | coord-net-contract | host-network-module | 1 | new: one `Attach`/`Detach`/`Verify` interface for P06, P07, P10, P11; callers remove the VM, then Detach (enforced: Detach refuses while the VM exists); a journal record before any change and a reconcile at module start; Attach returns the declaration: the guest's static address, gateway and resolvers on a private subnet (no DHCP; the consumers write them into the seed or answer file) and the declared endpoints, narrowed exceptions (one private address, TCP or UDP, one port), none by default; consumers read back from Hyper-V, through one shared pure check (`supervisor/network/AapHostNetworkCheck.psm1`), that every fixed range is denied inbound and outbound with nothing narrowing the deny, that there is no allow but the declared endpoints, each above every deny covering it by weight, port mirroring None and no trunk VLAN; a host with a public IPv4 address is not certified (limitation, owner decision queued); the one exception is DNS to one private resolver (UDP and TCP 53); the fixed list adds 255.255.255.255/32; clone-to-clone isolation (private VLAN isolated mode preferred) is a P02.1 decision; build VMs get their own switches (`aap-build-win`, `aap-build-linux`, P19 creates them) and never share one; `AAP_NetworkUnavailable`, `AAP_NetworkInvalid`, `AAP_NetworkUntrusted`, fail closed; shared strict fake in `tests/common`. `validate.py` gains its semantic rule for the declaration and the record, reading the fixed ranges from the shared check |
| 2026-10-21 | coord-net-contract | host-network-module | 1 | round 6: `released.json` written like a record (temporary name, flush, rename) and, when unreadable, stops Attach and Detach until the module's explicit recovery op rebuilds it from the records; Verify requires the gateway and a non-vEthernet host address in its discovery (`-HostLan`), the check reports a partial discovery; created names end in the record's VM id (schema pattern, validate.py) so Detach never removes another VM's or the host's object; the check refuses non-canonical (upper-case) IPv6; the guarantee is narrowed (public-address LAN targets, the router hairpin and host addresses outside the fixed ranges are residuals) and the clone-to-clone ARP residual blocks public repositories on the Windows profile until clone isolation is required and lab-proven. Schema: the `created` name pattern |
| 2026-10-21 | coord-net-contract | host-network-module | 1 (text only) | round 7: every Attach and Detach reads `released.json` first (a repeated Attach and a Detach with no record throw on an unreadable one); Detach writes the released list before removing the record (a crash between them keeps the address held); created names compare ordinally against the anchored `aap-<words>-<vm_id>` pattern; Verify throws on an `aap-guest-<vm_id>` adapter of an existing VM with no record, and the owner's remedy for an unreadable record is to remove the VM first; the guarantee names the private resolver exception; the public-repository gate covers both profiles. guest-transport.md follows |
| 2026-10-21 | coord-net-contract | guest-transport | 1 (text only) | Guest network attachment: the port ACLs deny both directions; no Allow names the host or the gateway, and no DHCP or DNS service runs for guests (static addressing from the network module's declaration); the only Allow is an exception the module declares, narrowed to one protocol, one port and one private address; one switch rule: internal switches only, never a private switch; build VMs on their own switches; guests attach only to switches P19 creates (or, per guest, the module); 255.255.255.255 denied; the ARP spoofing negative case split from the DHCP and RA one, with what the denies do and do not stop. No schema change |
| 2026-10-21 | coord-net-contract | host-network-module | 1 | round 5, from three reviews: a source pin (an outbound catch-all deny at weight 1 under an Allow from the guest's own address at 5; fixed denies at 10; the resolver exception at 20, also narrowed to the guest's address), a weight per rule class; the fixed list adds `0.0.0.0/8`, `127.0.0.0/8`, `240.0.0.0/4` and `::/0` (no guest IPv6), so no host-specific deny is needed; the read-back adds `Stateful`, `IsolationId`, `StormLimit` and `LegacyAcls`, and refuses unknown rule fields; one module-wide journal lock around allocation, least recently used addresses, exhaustion and unreadable records fail closed, only Hyper-V's definitive not-found frees an address, Verify reports an address two records hold and throws on an empty or gateway-less host discovery, which now includes every vEthernet prefix; the private resolver must be one of the resolvers; consumers re-Attach before every start (no stored declaration) and verify running guests on host address changes; a record naming a P19 switch is refused; clone-to-clone: permanent host neighbour entries with the source pin preferred, private VLAN only an add-on. No schema change |
| 2026-10-21 | P13.2 | cache-qualification | 2 (text only) | rule 6: a job is trusted only when its `head_sha` IS the default branch's head when the host binds the class (the branch-only ref endpoint `git/ref/heads/<default>` answers exactly that branch ref of that repository at `head_sha`; unknown means no shared root; only repositories the owner enabled), because GitHub's run record gives a tag push the tag's name as `head_branch` and has no ref field; replaces the reachability test of 2026-10-20. Runs superseded before binding and re-runs of older runs get a private root. No schema change |
| 2026-10-21 | P12 | status-settings | settings 3, status 5, revision 3 (text only) | landed: no longer drafts; the supervisor accepts settings 3 and writes `status.v5.json` only with the capacity module beside it, and without it writes `status.v5.json` with `settings_schemas` `[1,2]` (legacy pool, Windows `backend: none`); "What exists today" becomes "Before P12". No schema change |
| 2026-10-21 | P12 review | allocator | 2 (text and validate.py) | `per_profile` memory cap is `floor(pool_mem * share / (100 - reserve))`, the share of the memory pool after the control VM, instead of `floor(host.mem_gib * share / 100)`, which could let the two caps sum over the pool once the control VM is paid first (3 Linux at 60 % and 2 Windows at 30 % on 32 CPUs and 96 GiB asked 85 GiB of an 84 GiB pool, so the fifth slot was refused); the CPU cap is unchanged (its floors never sum over the pool). Fixtures: the owner example's Linux reservations are 18 GiB; `control-distro-memory-over-pool` is now refused by the Linux per-runner share. `allocator.json` stays schema 2 |
| 2026-10-21 | P12 review | status-settings | settings 3, status 5, revision 3 (text only) | compatibility: the tray never writes schema 2 over a stored schema 3 file (it writes schema 3 from the stored keys even while `status.v5.json` is stale, missing or newer), checks what it writes against the schema it writes, shows a stored schema 3 file's own counts, and treats an `updated` in the future as stale; a supervisor downgrade then needs `settings.json` removed. Status detail gains the reason word `grant_waits`. `generation_state` prose: the legacy pool reports `legacy-manager` (or its granted generation) as `active`. No schema change |
| 2026-10-21 | P04.1 | cache-qualification | 2 (text only) | rules 3 and 6 record that P04.1 added the Linux `debug-pdb` rows for every compiler version (matrix revision 2) and aligned retention.md requirement 4 with rule 6; no rule changes. No schema change |
| 2026-10-21 | P13.3 | cache-qualification | 2 (text only) | rule 7: a zero exit whose declared outputs (object, depfile) are missing, empty or not regular files is a wrapper failure; outputs the shim cannot name (rustc, other sidecars) rely on zccache's own delivery and P04's evidence. No schema change |
| 2026-10-22 | P02.5 | guest-transport | 2 | new `guest_identity` record (schema 2; the envelope documents stay schema 1) + `identity_exchange` test composite with an optional phased `reread` (`before_cleanup`: the same record again; `after_cleanup`: `null`): the host (P10 into the answer file, P11 into the cloud-init seed) writes the per-clone record OFFLINE at create, once the VM and its scratch disk exist — `vm_id`, `reservation_id`, `lease_generation`, expected scratch `size_gib` (the reservation's `scratch_gib`; the guest compares the disk's size rounded up to whole GiB, because the image is created a little under the cap) and `identity`, or null; the guest binds once at the first `probe` (replacing the first-writer `reservation_id`/`lease_generation` binding), takes its VM id from the record alone (not SMBIOS, not KVP), then follows one sequence, bind, cleanup, presence check: before cleanup the same record read again changes nothing, after cleanup any record found, identical or not, ends the clone; host-to-guest KVP stays off, so the credential's KVP sub-candidate (b) and the Linux seed-or-KVP choice are withdrawn (P06: KVP-on hands the job the host's fully qualified name), and the SMBIOS UUID is not the carrier (owner, 2026-10-21); `additionalProperties: false` (`scratch` too) + tight patterns so no host-identifying data rides it; fail-closed: missing or malformed record, two records, a scratch disk that does not match, a mismatched command (`refused`; `validate.py`: cmd vs record on `vm_id`/`reservation_id`/`lease_generation`), a different or second record before cleanup, a before-cleanup re-read beside a `listening`, `busy` or `job_done` reply (the guest deletes the material before it answers `listening`; the schema's `allOf` carries that rule), or any record after cleanup (`validate.py`: `reread`); admission: the wire cannot tell revision-1 from revision-2 agents, so only a generation whose catalog entry certifies a revision-2 guest agent is admitted, the rollback generation included (image-catalog row below); fixtures 5 valid + 18 invalid (a composite is one command and one reply, so they prove what one exchange may show, not the order across commands: that is the agent tests' and the lab's); lab cases added (another `reservation_id`, a swapped seed, material that reappears, an old-agent generation, host-to-guest KVP) |
| 2026-10-22 | P02.5 | image-catalog | 2 (additive; the catalog `schema` stays 2) | the `guest-agent` overlay carries `guest_transport_revision` (guest-transport.md, Admission): written by P21 from the agent's conformance record, never from a guest; `validate.py` requires 2 or later in every `approved`, `active` or `retired` generation (the retained rollback generation included; a `candidate` may lack the overlay) and refuses the field on any other overlay; rule 8: the supervisor's `approved-images.json` entry carries the revision beside the artifact hashes, every `create` (certification runs included) admits only a revision the host implements, and P25 refuses a rollback that fails it; fixtures: the two valid catalogs carry the revision, 4 new invalid (no revision, no guest-agent overlay, a revision-1 rollback generation, a revision on another overlay), and the 12 older invalid catalogs carry it too, so each fails for its own rule only |
| 2026-10-22 | P02.4 | host-network-module | 2 | host-neighbour poisoning protection: the owner adopts the contract's preferred control for the clone-to-clone ARP residual, narrowed to what it does: it protects host-to-guest delivery only (the entry is meant to keep a guest's ARP from moving the host's own entry, so what the host sends the guest, NAT return traffic included, is not redirected; its lab proof is open), not a guest's own ARP cache and not guest-to-guest frames; Limitations lists the clone-to-clone residuals and the per-guest switch stays the documented alternative. Attach gives the adapter a static MAC before the VM's first start, from a range the module owns (`02-A0-98-xx-xx-xx`, one copy in the shared check), and adds `New-NetNeighbor -State Permanent -InterfaceIndex <n>` for the guest's address and that MAC on the switch's management adapter, in the act with the adapter (a repeated Attach re-sets both, idempotent; the record's `created` lists the entry, `aap-neighbor-<vm_id>`). Before it changes anything Attach reads the host's entries for the guest's address on every interface as Verify does: none, it adds the entry; exactly the record's (address, MAC, `Permanent`, the management adapter's interface index and alias), idempotent success; anything else it throws `AAP_NetworkUntrusted` and never overwrites or replaces it; a failing read is a throw. After the add Attach reads the table back and throws when the entry is not exactly the record's. MACs are unique: Attach of a record refuses a MAC another record holds (any switch), and Verify reports it for both VMs (check 1) and reports another adapter on the VM's switch, the host's management adapters included, carrying the declared MAC (check 2, shared check `-PeerMacs`, Verify only). `-PeerMacs` omitted compares nothing (a consumer's read-back); supplied, as Verify always does, a null or empty list (the host's own adapter is always on the switch) or an entry that is not a MAC (twelve hex digits, dashed, colon or run together) is a problem, never read as no other adapter. The module resolves the switch's management adapter by identity (`Get-VMNetworkAdapter -ManagementOS -SwitchName`, `DeviceId` to `InterfaceGuid`, a lab point), never by alias text; Verify check 8 passes it as `-HostInterface` and requires exactly one entry, `Permanent`, the declared MAC, that interface's index and alias (shared check `-Neighbors`, module-only; a failing `Get-NetNeighbor` read is a throw, never a no-match). Detach removes exactly the record's own tuple (address, MAC, management adapter, any state) before the address is released, reads the table back, and a still-present entry, or a read that fails, throws and releases nothing. A record that is JSON but structurally damaged (a declaration that is not an object or lacks, or does not hold as non-empty text, a field the module reads back) is unreadable like one that is not JSON, always `the record of VM <id> is unreadable; it stays for an owner`, and both recovery ops still work while it is there. Attach and Detach of one VM run one at a time under a per-VM lifecycle lock (`lock-<vm id>`, taken before Hyper-V is asked about the VM, the journal lock inside it, 30 s wait; Verify takes the journal lock only), so a repeated Attach paused before its act cannot resume after a Detach and re-create the entry and adapter with no record. The owner's remedy for an unreadable record is ordered: remove the VM, clean up the neighbour entry (tuple from the record's text or from the orphan listing) with the neighbour recovery op (exact tuple, read back), only then delete the record; the orphan listing and the removal op are new owner-only recovery ops. Verify check 9 (the switch's enabled extensions against the set P19 recorded, no HNS network on it; shared check `Get-AapHostNetworkSwitchProblems`) is restored after the previous revision displaced it. The `mac` enters the declaration and the record (`host_network_attach`/`host_network_record` `schema` 2, the record names exactly one neighbour entry); contract version stays 2, no schema change. The provider read-backs gain `MacAddress`, passed through as read: a provider module is a module of its own and cannot see the check's functions, so the shared check normalises Hyper-V's own text, exactly twelve uppercase hex digits to the contract's dashed form, where check 2 compares it, and anything else compares as read and fails closed (the text Hyper-V prints is an open lab question); a test reads each of the four providers back in a fresh session beside a consumer module that holds the check. PVLAN stays an optional lab add-on (expected negative alone), the check keeps refusing `VlanMode` `Private` (fail closed), and the lab questions (the two-guest captures, a static MAC through Windows Setup and cloud-init, Hyper-V's own MAC text, `New-NetNeighbor` on an existing entry, the `DeviceId` mapping, the extension baseline) stay open. Fixtures: `attach-mac-missing`, `attach-mac-form`, `attach-mac-range`, `attach-schema-1`, each invalid for one reason only; every other invalid fixture of this contract is built to fail for one reason too (a record fixture names its one neighbour entry; an endpoint fixture carries the same bad address in both endpoints and, where that address is well formed, in the resolvers); shared fake tampers `adapter-mac`, `neighbor-missing`, `neighbor-mac`, `neighbor-state`, `neighbor-interface`, `neighbor-unreadable`, `neighbor-add-lost`, `neighbor-stuck`, `peer-mac-clash`, `switch-extension`, `switch-extension-off`, `hns-network`, `switch-unreadable` (the former `neighbor-foreign` is now a planted entry, `Add-AapFakeHostNetworkNeighbor`), fault `DetachAfterNeighbor` and pause `AttachBeforeAct` |
| 2026-10-22 | P09.x (owner decision Q4, with the second-family review) | status-settings, allocator, backend-lifecycle, vm-cap-notes (new), lifetime-clock (new) | settings 4 (3 still read), status 5 revision 4; allocator 2 (text only); backend-lifecycle 3 (records `schema` 2); vm-cap-notes 1; lifetime-clock 1 | hard 6-hour VM lifetime cap replaces the flag-only wall clock, with two independent enforcers. Supervisor path: from `acquired_at`, latch in memory, concurrently dispatch every due hypervisor power-off, then persist clock/allocator/journal records and perform verified teardown; calls isolated and bounded to 30 s, one non-power-off call at a time, 90 s supported lateness; fencing prevents resurrection and only teardown proof frees capacity. Persisted high-water time and boot id/counter recover same-boot restarts; reboot or missing/invalid clock state fails closed for running VMs. Host backstop: separate watchdog uses a validated Notes deadline and VM GUID/name identity, independent of allocator/journal/backend (300 s supported lateness), and fails closed on clock loss. The mandatory installer gate reconciles every pre-existing VM to a valid record or verified absence before profile activation. Settings schema 4 cap, status fields, after-power-off journal evidence, validator and fixtures described above; `allocator.schema.json` remains unchanged. Consumers not yet conformant |
| 2026-10-24 | P09.x delta review | allocator, backend-lifecycle, lifetime-clock, status-settings | contract revisions unchanged (unmerged) | fair concurrent watchdog scheduling with durable E1/E2 stages and complete 50 s run budgets; 300 s to observed Off or an explicit unresolved cap breach, never network detachment as termination; clock-safety triggers allow unknown or below-cap elapsed evidence; journal issuance/persistence ordering uses high-water estimates through wall-clock rollback; valid/invalid fixtures and regression/mutation tests updated |
