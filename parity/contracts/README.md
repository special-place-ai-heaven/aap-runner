# Shared parity contracts (ledger item P02)

Frozen interfaces for the GitHub-runner parity work. The architecture they implement is
[docs/parity/ARCHITECTURE.md](../../docs/parity/ARCHITECTURE.md). A change to a contract is a
ledger revision first, then a new contract version; no worker edits these files opportunistically.

```
python -I parity/contracts/validate.py                       # every fixture, exit 0 = all hold
python -I parity/contracts/validate.py <contract> <file>...  # validate real documents
```

`validate.py` is standard library only. It implements the draft 2020-12 keywords these schemas
use, refuses any other keyword, and adds each contract's cross-field rules. Each invalid fixture
names the error it must produce, so it cannot pass for the wrong reason.

## Index

| Contract | Version | Files | Writer | Readers | Status |
|---|---|---|---|---|---|
| [Allocator](allocator.md) | 1 | `allocator.schema.json` | P09 | P10, P11, P12, P16, P20, P22 | DECIDED |
| [Backend lifecycle](backend-lifecycle.md) | 1 | `backend-lifecycle.schema.json` | P10, P11 | P09, P12, P19, P22, P25 | DECIDED; budgets measured later |
| [Broker](broker.md) | 1 | `broker.schema.json` | P08 | P10, P11, P14, P15, P16, P26 | DECIDED; JIT runner behaviour CANDIDATE (D2) |
| [Guest transport](guest-transport.md) | 1 | `guest-transport.schema.json` | P10/P11 host, P14/P15 guest | P22, P26 | envelope DECIDED; mechanisms CANDIDATE (D2) |
| [Image catalog](image-catalog.md) | 1 | `image-catalog.schema.json` | P21, P25 | P06, P07, P10, P11, P12, P19, P20, P24 | DECIDED |
| [Cache qualification](cache-qualification.md) | 1 | `cache-qualification.schema.json` | P04 | P13, P14, P15, P16, P20, P22, P24 | DECIDED |
| [Status and settings](status-settings.md) | settings 3, status 5 (drafts); tray-local 1 | `settings-v3`, `status-v5`, `tray-windows-choice` schemas | P12, P20 | P19, P22 | shape DECIDED, lands in P12 |
| [Evidence and cleanup](evidence-cleanup.md) | 1 | `evidence-bundle`, `cleanup-receipt` schemas | P05, P00 | every item, P24, P26, P28 | DECIDED |

## Decided

1. One five-slot allocator in the hidden supervisor counts every backend, including the legacy
   WSL pool, which is adopted before any VM registers.
2. Two live controls (Linux 0-5, Windows 0-5, sum 1-5), a never-allocated host reserve (floor 10 %),
   `even` shares by default and `per_profile` shares on request (the owner's 30/60/10 example).
3. Reservations persist before boot or registration, carry a lease generation, and are freed only
   by observed teardown; lost heartbeat holds capacity.
4. Provider interface, idempotency keys, intent/outcome journal, crash recovery, disk layout and
   measured-only budgets.
5. App key stays root-only in the control distro; the broker is a fixed-path one-shot root program
   called over `wsl.exe` stdin/stdout with bounded, attacker-choice-free requests; one JIT config
   per lease id; replay, skew, stale-generation and lease-limit refusals; secret-free audit.
6. JIT config instead of registration tokens for VM guests, delivered in memory and consumed as
   `ACTIONS_RUNNER_INPUT_JITCONFIG`, never argv or a file.
7. The fixed management command set, echo/sequence/nonce replay rules and hostile-reply handling.
8. Immutable catalog generations tied to the P01 baselines, one active per profile, one retained
   rollback, quarantine is final.
9. zccache 1.15.6 only, per-pair qualification, direct compilation otherwise, no sccache.
10. `status.json` stays schema 4; schema 5 is `status.v5.json`; settings schema 3 is written only
    when advertised; unknown future schemas are rejected safely on both sides.
11. Evidence record and both receipt shapes, with independent verifiers and observed absence.

## Candidate pending D2 lab proof

1. PowerShell Direct as the Windows management channel, including credential bootstrap by offline
   unattend or KVP, and safe handling of hostile deserialized output.
2. SSH over a Hyper-V socket for Ubuntu with KVP host-key pinning (fallback: per-clone isolated switch).
3. Guest network isolation (internet only; no host, WSL distro, LAN or other guests) on Hyper-V.
4. End-to-end JIT runner behaviour on the pinned runner release: environment input consumed and
   masked, one job, registration gone afterwards, unused runner deletion, no copy left in the guest.
5. Destroy-and-recreate per job versus a cheaper reset (reset stays unused without proof).
6. Measured disk, memory and IO budgets per generation.
7. hvsocket service registration through the existing elevated helper (P19).

## Open decisions

These need the owner (or a coordinator ledger revision) before the named item starts:

1. **Runner labels and group for the VM profiles** (blocks P08, P23). Proposal: Windows
   `self-hosted, Windows, X64, aap-win25-vs2026`; Ubuntu `self-hosted, Linux, X64, aap-ubuntu-24.04`;
   group `aap-crrr`. Labels decide routing for every consumer workflow.
2. **`<image_root>` volume** for base, clone, scratch and rollback disks (blocks P06, P10). Must be
   a fixed local NTFS or ReFS volume with the measured budget free.
3. **Control distro uptime.** The broker lives in the WSL distro, so the distro (and Vmmem) must
   run whenever a VM profile is on, even with Linux at 0. The current supervisor makes no
   `wsl.exe` call while off; that stays true only while both profiles are off.
4. **Host reserve floor.** 10 % follows the owner's example; confirm it as the minimum.
5. **Gate D2** itself: Windows Server 2025 media and activation, lab host and budget.

## Findings recorded while freezing

- `supervisor/README.md` and the supervisor still limit `windows_runner_count` to 0..4 (schema 2,
  correct while no Windows backend exists); settings schema 3 widens both counts to 0..5.
- The current tray treats `status.json` schema 5 as an error, hence the separate `status.v5.json`.
- The P01 cleanup receipt's `reviewed_head` is not a full SHA (see evidence-cleanup.md).
