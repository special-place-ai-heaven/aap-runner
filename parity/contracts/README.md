# Shared parity contracts (ledger item P02, revised by P02.2)

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
| [Allocator](allocator.md) | 2 | `allocator.schema.json` | P09 | P10, P11, P12, P16, P20, P22 | DECIDED |
| [Backend lifecycle](backend-lifecycle.md) | 2 | `backend-lifecycle.schema.json` | P10, P11; storage document P19 | P09, P12, P19, P20, P22, P25 | DECIDED; budgets and cap enforcement measured later (P02.1, P06, P07) |
| [Broker](broker.md) | 1 | `broker.schema.json` | P08 | P10, P11, P14, P15, P16, P26 | DECIDED; JIT runner behaviour CANDIDATE (D2) |
| [Guest transport](guest-transport.md) | 1 | `guest-transport.schema.json` | P10/P11 host, P14/P15 guest | P22, P26 | envelope DECIDED; mechanisms CANDIDATE (D2) |
| [Image catalog](image-catalog.md) | 2 | `image-catalog.schema.json` | P21, P25 | P06, P07, P10, P11, P12, P19, P20, P24 | DECIDED |
| [Cache qualification](cache-qualification.md) | 2 | `cache-qualification.schema.json` | P04 | P13, P14, P15, P16, P20, P22, P24 | DECIDED |
| [Status and settings](status-settings.md) | settings 3, status 5 (drafts, revision 2); tray-local 1 | `settings-v3`, `status-v5`, `tray-windows-choice` schemas | P12, P20 | P19, P22 | shape DECIDED, lands in P12 |
| [Evidence and cleanup](evidence-cleanup.md) | evidence 2, receipt 1 | `evidence-bundle`, `cleanup-receipt` schemas | P05, P00 | every item, P24, P26, P28 | DECIDED |

## Decided

1. One five-slot allocator in the hidden supervisor counts every backend, including the legacy
   WSL pool, which is adopted before any VM registers.
2. Two live controls (Linux 0-5, Windows 0-5, sum 1-5), a never-allocated host reserve (floor 10 %),
   `even` shares by default and `per_profile` shares on request (the owner's 30/60/10 example).
3. Reservations persist before boot or registration, carry the slot's lease generation, and are
   freed only by observed teardown. Admission checks shares at admission; pool, disk and IO budgets
   count every live reservation, so draining overhang delays the other profile. Three missed
   heartbeats quarantine with capacity held; a heartbeat restores the slot; destroy waits until
   GitHub reports the runner offline and not busy, or the job ends (a busy runner is never
   destroyed, only flagged past `lease_wall_clock_hours`); hostile guests go straight to deletion.
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
   rules, hostile-reply handling, and the guest network enforcement shape.
7a. JIT secrecy: no copy outside the runner's root and processes; destroy is the control; `reset`
   forbidden; the runner starts as `Runner.Listener` directly.
8. Immutable catalog generations tied to the P01 baselines, one active per profile, one retained
   rollback, quarantine is final.
9. zccache 1.15.6 only, per-pair qualification, direct compilation otherwise, no sccache.
10. `status.json` stays schema 4; schema 5 is `status.v5.json`; settings schema 3 is written only
    when advertised; unknown future schemas are rejected safely on both sides.
11. Evidence record and both receipt shapes, with independent verifiers and observed absence;
    waivers are listed in the record (revision 2).
12. Storage tiers (owner, 2026-10-20): configurable `base_root`, `clone_root`, `scratch_root` and an
    optional `staging_root`, set only through the elevated helper and never from the inbox; each
    passes the ProgramData trust checks at install, at every supervisor start and before every
    `create`; no defaults and no hard-coded drive letters; per-volume disk admission with a
    free-space floor (backend-lifecycle.md, allocator.md).

## Candidate pending D2 lab proof

The transport lab proof is a **single-owner ledger child, P02.1**, which gates P10/P11 fan-out
(the coordinator adds it to the ledger). Its prerequisites are gate D2 plus a **lab GitHub App**
and a **test org and repository**, so the lab never uses the production App, key or org. Plan:
[guest-transport.md](guest-transport.md#lab-proof-plan-p021-executed-for-p08-p10-p11).

1. PowerShell Direct as the Windows management channel, including credential bootstrap by offline
   unattend or KVP, and safe handling of hostile deserialized output.
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
   storage budget must still be measured and approved before any VM is created, so D2 stays
   partly met until then.

## Resolved 2026-10-20

1. **Storage tiers** (owner). Nothing for the Windows runner lives on the NVMe system volume. The
   image area is no longer one hard-coded root: the installer and the owner choose `base_root`,
   `clone_root`, `scratch_root` and optionally `staging_root`, which may share one volume or use
   several ([backend-lifecycle.md, Storage tiers](backend-lifecycle.md#storage-tiers-decided-owner-2026-10-20)).
   The owner is enlarging the dedicated volume `E:` (`winrunner`, 195 GB on 2026-10-20, target
   about 600 GB), a partition of the USB disk that also holds the owner's data volume `D:`.
   Partitions and volumes are the owner's: no item creates, resizes, formats, relabels or
   re-letters one, or changes a volume root's ACL.
2. **Sizing evidence.** The hosted Windows image at job start uses 127,436,206,080 bytes of a
   160 GB `C:` with 33,031,553,024 free, and 3.2 GB of a 161 GB `D:` (run 39303666617), on 4 vCPU
   and 16 GiB. Planning estimate: 130-140 GB per base generation plus build headroom, 20-50 GB per
   running job, plus one rollback generation (backend-lifecycle.md, Sizing evidence).

## Open decisions (2026-10-20)

1. **Volume-root ACLs** (owner, with a security review). A root's ancestors include its volume
   root. Read on 2026-10-20: `E:\` grants Authenticated Users Modify, which includes delete, and
   `D:\` grants Everyone full control, so every root on either volume fails the ancestor check and
   the VM profiles stay off. Either the owner changes the volume root's ACL (an owner action; no
   item does it), or a reviewed rule change ignores the delete right alone on a volume root
   directory, which cannot be deleted or renamed, while delete-child, change-permissions,
   take-ownership and full control still fail. Until then the strict rule holds.
2. **Floor value** (owner): `volume_floor_gib` for the owner's volume; the contract minimum is 10.
3. **Where the roots are configured** (coordinator): this revision keeps them out of settings
   schema 3 and in the admin-only storage document that only the elevated helper writes, because
   the inbox is user-writable ([status-settings.md](status-settings.md#storage-in-status-schema-5-draft-revision-2)).
   The tray shows them from `status.v5.json` and offers a helper verb to change them (P19, P20).
4. **Lab budget** (owner, gate D2): the compute and storage budget for the lab is still to be
   approved before any VM.

## Security review (2026-10-19) items carried by other owners

- **P10.0 guest network module** (new ledger item, coordinator adds it): the one shared guest
  network module for P10 and P11, implementing the enforcement shape in guest-transport.md.
- **P02.1**: lab cases added for crafted CLIXML, remote host-UI calls, stream floods, a
  guest-replaced endpoint, IPv6 and host-port reachability, ARP/DHCP/RA spoofing, WSL mirrored
  mode, host PowerShell 4103/4104 and transcription, and a stolen runner credential; plus the
  framed-hvsocket comparison for Windows.
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
- **P04.1**: add the Linux `debug-pdb` (`-g`) rows for every compiler version (8 more rows at
  P04's versions) now that a matrix may hold 256 rows.
- **P05.1**: write waivers into the evidence record's `waivers` field and stop appending them to
  `command`; until then `parity-report.json` and `verdict.json` stay authoritative. Nit: the
  harness's `re.match(...$)` checks for workload ids and SHAs accept one trailing newline (Python
  `$`); `validate.py` now rejects such values in the records.
- **P07, P11**: match the hosted Ubuntu kernel, `read_ahead_kb` and mount options, or justify each
  difference with a reviewed allowlist entry (image-catalog.md, Acceptance input).
- **P09**: `allocator.json` schema 2 (per-volume disk budgets, reservation `clone_gib` and
  `scratch_gib`).
- **P13**: cache roots per repository plus ref trust class (cache-qualification.md rule 6).
- **P19, P20**: the storage document, its helper verb and the tray's storage view.

## Findings recorded while freezing

- `supervisor/README.md` and the supervisor still limit `windows_runner_count` to 0..4 (schema 2,
  correct while no Windows backend exists); settings schema 3 widens both counts to 0..5.
- The current tray treats `status.json` schema 5 as an error, hence the separate `status.v5.json`.
- The P01 cleanup receipt's `reviewed_head` was not a full SHA on 2026-10-19; the coordinator
  corrected it, and all six receipts in the evidence store pass on 2026-10-20.
- Before revision 2, `validate.py` used Python's `$`, which also matches before a final newline, so
  a value with one trailing newline passed its pattern. Patterns now anchor at the end of input,
  as in ECMA-262.

## Revision log

| Date | Item | Contract | Version | Change |
|---|---|---|---|---|
| 2026-10-19 | P02 | all | 1 (settings 3, status 5 drafts) | frozen |
| 2026-10-20 | P02.2 | cache-qualification | 2 | `maxItems` 64 to 256; Linux `debug-pdb` (`-g`) rows for every compiler version; rule 6 namespace is the repository plus the ref trust class. Matrices keep `schema` 1 |
| 2026-10-20 | P02.2 | evidence-cleanup | evidence 2, receipt 1 | optional bounded `waivers`; records keep `schema` 1 |
| 2026-10-20 | P02.2 | backend-lifecycle | 2 | storage tiers and the `storage` document; tier-relative disk paths; budget caps `clone_gib_max` and `scratch_gib_max`; records `schema` 2 |
| 2026-10-20 | P02.2 | allocator | 2 | per-volume disk admission: `host.volumes`, reservation `clone_gib` and `scratch_gib`; `allocator.json` schema 2 |
| 2026-10-20 | P02.2 | image-catalog | 2 | catalog at `<base_root>\catalog.json`, artifact paths relative to `base_root`, catalog `schema` 2; P07/P11 acceptance input from P05 |
| 2026-10-20 | P02.2 | status-settings | status 5 draft, revision 2 | `storage` in `status.v5.json`; settings schema 3 unchanged, no paths |
| 2026-10-20 | P02.2 | guest-transport | 1 (text only) | lab storage preconditions and the budget step (step 8); envelope unchanged |
| 2026-10-20 | P02.2 | validate.py | - | `$` is the end of input; documents bounded to 256 KiB (a 256-row matrix is about 90 KB) |
