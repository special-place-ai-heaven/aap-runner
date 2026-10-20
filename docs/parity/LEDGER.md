# Parity implementation ledger

Revision 3 (executing since 2026-10-19; D0 authorized). Status as of 2026-10-20 on origin/main `88a9a25`: P00, P01, P02, P03, P04, P05, P06, P08, P09, P17, P20.0 and the child P02.2 are COMPLETE, P18 is MERGED_CLEANUP_REQUIRED (waiting for the independent cleanup verifier), P10 and P13 have open PRs, P07 is in progress; wave 5 is current. States below are current; everything not listed otherwise is NOT_STARTED. `ledger.json` is the machine-readable dispatch/ownership source. These are proposed paths; commands and oracles are implemented by the owning task before they can certify an outcome. Every item uses the merge-and-clean lifecycle in [WORKTREES.md](WORKTREES.md). Only `COMPLETE` dependencies unlock work; merged or gate-verified alone does not.

## Owner decisions and open gates

- 2026-10-19: native Windows runner is the critical path (Windows chain first after P02); the live five-runner legacy pool is untouched until certified cutover (D5); per-profile resource shares are a hard requirement (example 30 % Windows / 60 % Linux / 10 % owner desktop); agents merge reviewed green PRs, the owner never merges; profile counts are two live controls, Linux 0-5 and Windows 0-5 with a total of at most 5.
- 2026-10-20 lab budget approved (gate D2 budget met), `E:\aap-runner` only: base generation <= 200 GB, rollback generation <= 200 GB, per-runner clone+scratch <= 60 GB, at least 15 % of the volume free; one build VM at a time with 4 vCPU and 10 GiB static RAM at the lowest scheduling weight; internal switch + NAT only. `E:\` root locked to Administrators 2026-10-20. Windows Server 2025 Evaluation ISO provided and verified.
- Partitions and volumes are never touched; only plain files inside `E:\aap-runner\` after approval.
- Interim Windows host runner approved unisolated (group `aap-win-interim`, label `windows-host-interim`); retire it when the VM profile is certified. It can reach the App key, an accepted risk that is a precondition to close before the App gains permissions.
- PENDING: zccache 1.15.6 AGPL-3.0-only compliance decision (images containing it must not be redistributed until decided).
- PENDING: GitHub App `actions: read` + `contents: read` for cache trust-class lookups (gates P02.3 and P13 activation).

## P00 — Build the worktree, lease and cleanup gate

- Earliest wave: 1; prerequisites: execution authorization only.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `tools/parity-work/**`, `tests/parity-work/**`, plus the `pester` job `Run.Path` line of `.github/workflows/ci.yml` (coordinator-authorized).
- Deliverable: Implement atomic claims, task resource manifests, merge-proof validation, independent cleanup receipts and a global no-new-dispatch barrier. This prerequisite lands before any other implementation task.
- Acceptance: Dirty/unowned files, squash/rebase merges, stale PID, junction/ADS/traversal, locked file, interrupted cleanup and overlapping claims fail closed; a merged-but-unclean prerequisite never unlocks work. Concurrent junction substitution cannot escape a qualified no-follow/protected deletion boundary; static preflight scans alone do not qualify. Parent merge-readiness requires children merged and cleaned without circular parent dependencies.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #23 merged at `90ef9b6` (merge commit, accepted head `52e73bd`, CI run 39292847649 green); attempt-1 cleaned and independently verified (receipt in the parity evidence store).

## P00.1 — Harden the cleanup gate (review follow-ups)

- Earliest wave: 2; prerequisites: P00.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `tools/parity-work/**`, `tests/parity-work/**`.
- Deliverable: Land the non-blocking findings from the 2026-10-19 code and security reviews of P00 (see `ledger.json` P00.1 for the full list), plus the build/test/resource tokens and the 3-worker/2-compile/1-suite/1-IO budgets enforced at claim. The budgets must land before wave 4 dispatches P03/P04/P05 in parallel.
- Acceptance: Each listed finding has a test that fails without its fix; both PowerShell hosts green; budgets refuse a fourth worker, a third compile-heavy job and a second full suite.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P01 — Freeze hosted baselines and consumer inventory

- Earliest wave: 2; prerequisites: P00.
- Pinned execution lane: Luna medium; ownership: `parity/baselines/**`.
- Deliverable: Capture exact Windows Server 2025/VS2026 x64 and Ubuntu 24.04 x64 hosted image identities, upstream commits, full inventories, defaults, source inputs and selected consuming repositories. Capture the real hosted Set up job image reference.
- Acceptance: Every upstream inventory entry is accounted for; cached versions and environment/service defaults included. Moving labels and mismatched hosted generations invalidate evidence. Exact unresolved source/media/licensing inputs are recorded.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #28 merged at `fc3bbc6` (accepted head `c005e94`), attempt-1 cleaned and independently verified; baselines — inventories 382/382 and 224/224 verified, baselines pinned to the build commits (Windows `aee0669` → image 20261007.264.1, Ubuntu `7e7dc1b` → 20261012.334.1), hosted captures recorded; open licensed/unreproducible inputs listed in the profile `inputs.md` files.

## P02 — Freeze architecture and shared contracts

- Earliest wave: 3; prerequisites: P01.
- Pinned execution lane: Sol high; ownership: `parity/contracts/**`, `docs/parity/ARCHITECTURE.md`.
- Deliverable: Specify immutable image/catalog, host-wide resource lease, backend lifecycle, guest bootstrap, auth/JIT transport, cache qualification, status/settings compatibility, evidence and cleanup schemas. Prove management transport feasibility in an explicitly authorized disposable lab before backend fan-out.
- Acceptance: Independent security review; concrete schema examples and negative fixtures; no missing interface decision delegated to two workers. Preserve App key custody in existing control distro. PR20 is merged and reconciled before consumers depend on its helper APIs.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #29 merged at `ef70297` (merge commit, accepted head `5f69452`, reviewed head `3a52d44`; hosted CI bash/pester/tray green); attempt-1 cleaned and independently verified (receipt in the parity evidence store). ARCHITECTURE.md plus 8 contracts, 11 schemas and fixtures validated (35 valid, 98 invalid); architecture and security reviews applied (3 high / 7 medium / 4 low closed); owner decisions 2026-10-19 (labels, D:\aap-runner\images, distro uptime, 10 % reserve floor, eval ISO) recorded in parity/contracts/README.md. Revised by P02.2; the lab transport proof remains P02.1.

## P02.1 — Prove guest management transport and isolation in the authorized lab

- Earliest wave: 4; prerequisites: P02 and gate D2 (eval ISO, lab GitHub App and test org/repo, approved compute/storage budget).
- Pinned execution lane: Sol high (Claude: Opus xhigh); ownership: `parity/contracts/lab/**`, `docs/parity/evidence/lab/**`.
- Deliverable: execute the `guest-transport.md` lab plan (PowerShell Direct through an isolated child process and the hvsocket framed-protocol comparison; SSH over hvsocket with pinned host key; credential bootstrap; replay/nonce/echo; hostile, oversized and guest-replaced endpoints; guest network isolation matrix with a positive egress oracle; JIT end to end; measured budgets) and freeze the chosen sub-candidates as a contract revision. Single owner; gates P10/P11 fan-out.
- Acceptance: every lab case observed; all isolation negatives refused; no secret in host events 4103/4104, transcripts or guest files outside the runner root; independent security review of the evidence; never on the live pool.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P02.2 — Revise the frozen contracts after the P03-P05 reviews and the storage decisions

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `parity/contracts/**`, `docs/parity/ARCHITECTURE.md`.
- Deliverable: Contract revision after P02 (additive and backward compatible where possible): separate base/clone/scratch/staging roots in an admin-only storage.json with no hard-coded drive letters, allocator/backend-lifecycle/image-catalog schema 2, cache-qualification 256-row matrices with the cache trust namespace = repository + the job trust class (event, ref, head repository), optional evidence-bundle waivers bound to their workload, validate.py storage/waiver/anchoring rules (+ lint), status-v5 storage reporting, P09 contract points.
- Acceptance: validate.py PASS with the revised fixtures; independent code and security review with fix rounds; nothing live touched; mutation script kills every injected contract break.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #34 merged at `544d2d0` (accepted head `9678a30`; hosted CI green; validate.py 43 valid / 150 invalid, mutation 34/34 killed); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Gaps: the job trust-class lookup needs the pending App permission decision (P02.3); retention.md alignment (P04.1).

## P02.3 — Add the guest-transport bind_cache command for cache trust-class binding

- Earliest wave: 6; prerequisites: P02.2.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `parity/contracts/**`.
- Deliverable: Specify a one-shot guest-transport command bind_cache (at most 1 KiB) that binds the job's cache trust class (event, ref, head repository) to the guest cache root, with schema, positive and negative fixtures and the broker-side narrowed per-lookup token flow.
- Acceptance: validate.py PASS with the new fixtures; oversized, replayed, unbound-class and arbitrary-exec negatives refused; independent security review. Requires the owner decision on giving the GitHub App actions:read + contents:read for cache trust-class lookups (installed only on the aap-crrr runner group's repositories); never implemented against the live App before that decision.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED. Open input: owner decision on the GitHub App `actions: read` + `contents: read` grant for cache trust-class lookups (PENDING), with the interim-runner/App-key exposure closed first.

## P03 — Implement verified artifact acquisition

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Luna high; ownership: `images/common/**`, `tests/images/common/**`.
- Deliverable: Download and retain reviewed upstream install inputs with hashes, provenance, licenses/redistribution restrictions and bounded retry; support offline staging. Do not pipe remote installers into a shell or silently float versions.
- Acceptance: Corrupt input, expired/changed upstream installer, interrupted publication and unavailable source reject the candidate. Unreproducible inputs remain explicit blockers, not omitted packages.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #32 merged at `9ff0da3` (accepted head `ac13d05`; hosted CI green; Pester 217/217 on both hosts); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Gap: the actions/runner-images trees and the Ubuntu server ISO are not yet in the manifest (P03.1).

## P03.1 — Pin the hosted-image script trees and the Ubuntu server ISO in the acquisition manifest

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/common/artifacts.manifest*.json`, `images/common/New-AapManifest.ps1`, `tests/images/common/**`.
- Deliverable: Add the actions/runner-images trees for the pinned build commits aee0669 (Windows) and 7e7dc1b (Ubuntu) to the P03 manifest so the 82 null upstream script hashes in P06 (and the P07 equivalents) become non-null; add the Ubuntu 24.04 server ISO entry with hash, provenance and license.
- Acceptance: No consumer script hash is null; builds no longer stop with AAP_ScriptUnpinned for lack of a pin; a changed or corrupt tree and a missing ISO hash are rejected by tests; unreproducible inputs remain explicit blockers.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P04 — Qualify zccache 1.15.6 interfaces and platforms

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `parity/cache/qualification/**`, `tests/parity/cache/qualification/**`.
- Deliverable: Use zackees/zccache tag 1.15.6 and versioned documentation. Verify Linux musl evidence, Windows artifacts, Rust, GCC/Clang, clang-cl, cl.exe/link.exe, response files, paths, daemon/retention and unsupported invocation behavior.
- Acceptance: Uncached/cold/warm compiler exit codes and artifacts agree; deliberate errors remain errors; unsupported/unqualified modes run direct compilers. Windows archive availability alone is not a pass. No sccache fallback.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #31 merged at `a127534` (accepted head `81a459a`; hosted CI green; Pester 85/85 on both hosts, 11/11 unittest); attempt-1 cleaned and independently verified (receipt in the parity evidence store) (merged content identical to the reviewed head). Gaps: all 85 matrix rows run direct compilers, Linux `-g` rows and retention.md alignment (P04.1).

## P04.1 — Extend the zccache qualification matrix and align retention with cache rule 6

- Earliest wave: 5; prerequisites: P04.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `parity/cache/qualification/**`, `tests/parity/cache/qualification/**`.
- Deliverable: Extend the Linux -g rows and land the harness follow-ups from the P04 reviews; align retention.md requirement 4 with cache rule 6 revision 3 (trust namespace = repository + job trust class).
- Acceptance: Every new row has a recorded direct-versus-cached comparison or an explicit unqualified marker; retention.md no longer contradicts cache-qualification.md rule 6; Pester and unittest suites green on both PowerShell hosts and in hosted CI.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P05 — Build differential certification harness

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Luna high; ownership: `tools/parity-certify/**`, `tests/parity-certify/**`.
- Deliverable: Produce allowlisted machine-readable job-process inventory, environment/capability probes, reference/local comparison, first-causal-error classification and evidence bundles. Canonicalize only documented machine-specific differences.
- Acceptance: Remove a non-default cached version, alter PATH order or SDK variable, skip a workload, mismatch source/action/image SHA or forge a green log: comparison fails. Inventory and behavioral results cannot substitute for each other.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #30 merged at `1a2741a` (accepted head `7d86d78`; hosted CI green; Pester 82 passed / 1 honest skip on both hosts); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Gaps: waivers, exit_code binding and the `$` regex anchor (P05.1).

## P05.1 — Harden the certification harness (waivers, exit_code binding, regex anchor)

- Earliest wave: 5; prerequisites: P05, P02.2.
- Pinned execution lane: Luna high; ownership: `tools/parity-certify/**`, `tests/parity-certify/**`.
- Deliverable: Use the evidence-bundle waivers field in certify and bind exit_code; fix the certify.py re.match $ trailing-newline acceptance (use fullmatch or \Z).
- Acceptance: Each fix has a test that fails without it; a waiver unbound to its workload is refused; a trailing-newline value is rejected; both PowerShell hosts green.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P06 — Build the native Windows image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/windows/**`, `tests/images/windows/**`.
- Deliverable: Port the pinned VS2026 upstream provisioning order to the approved local VM builder. Preserve reboots, users, environment, tool cache, services, upstream tests/software reports, sysprep and activation/source requirements.
- Acceptance: Fresh guest and actual job user pass full inventory/upstream tests; native compiler/SDK/resource discovery works. No host-specific credential or App key in image. Measure image, staging, replacement and scratch storage; do not inherit the 60 GiB Linux default.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #38 merged at `c621999` (accepted head `d0169ca`; hosted CI run 39354581645; Pester 254/254 on both hosts; mutation 53/53); attempt-1 cleaned and independently verified (receipt in the parity evidence store). No real build has run (D2 lab first); 82 upstream script hashes null until P03.1; per-test waivers and the secret-scan skip list are P06.1. `tests/images/windows` entered CI with PR #41.

## P06.1 — Per-test waivers for the verify phase and a reviewed secret-scan skip list

- Earliest wave: 6; prerequisites: P06, P02.2.
- Pinned execution lane: Luna high; ownership: `images/windows/**`, `tests/images/windows/**`.
- Deliverable: The verify phase needs failed-test names in the verify reply to apply per-test waivers; extend the reviewed secret-scan skip list from D2 evidence (currently only System Volume Information).
- Acceptance: Waivers apply only to named failed tests bound to the workload; every skip-list entry cites observed lab evidence; Pester green on both hosts. Skip-list extension needs a real build from the D2 lab, so that part is gated on P02.1/D2.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED (skip-list part gated on a D2 lab build).

## P07 — Build the Ubuntu 24.04 VM image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/ubuntu-24.04/**`, `tests/images/ubuntu-24.04/**`.
- Deliverable: Build the full pinned Ubuntu 24.04 VM environment using upstream install/config/tool-cache/test/post-generation logic, with guest-only passwordless sudo, systemd and baseline container capabilities.
- Acceptance: All inventory categories and cached versions verified; fresh job shell/environment and baseline services work. No Ubuntu 26.04; Sysbox compatibility is not certified as full VM equivalence.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS — attempt-1 worktree on `parity/p07-ubuntu-image` (base `4637f84`), authoring with fakes only; not yet pushed. Real builds stay refused until P03.1 pins the script hashes.

## P08 — Implement protected registration and management transport

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `supervisor/broker/**`, `distro/worker-auth.sh`, `tests/worker_auth_test.sh`, `tests/broker/**`.
- Deliverable: Keep App signing/key use root-only in the existing control distro; expose a fixed bounded lease/profile operation. Prefer verified one-use JIT config; never describe a reusable registration token as one-use. Deliver sensitive material through the qualified management channel without argv, logs, inbox or golden-image persistence.
- Acceptance: Expired/replayed/stale lease, arbitrary command/path, malformed request, cross-guest request, reparse transport and unavailable broker produce no registration. Secret-marker tests prove absence in logs, artifacts, state and guest images.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #33 merged at `f36ae7e` (accepted head `36c23e3`; hosted CI run 39353711710 incl. worker_auth_test on real Linux; Pester 24/24 on both hosts); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Non-blocking notes are P08.1. `tests/broker` and shellcheck entered CI with PR #41.

## P08.1 — Land the P08 non-blocking broker notes

- Earliest wave: 5; prerequisites: P08.
- Pinned execution lane: Luna high; ownership: `supervisor/broker/**`, `distro/worker-auth.sh`, `tests/broker/**`, `tests/worker_auth_test.sh`.
- Deliverable: Move the audit log dir from /var/log to /var/lib/aap-runner/broker; rm -f the lease file on create failure only when it is empty; raise the client TimeoutSeconds floor to 60; correct the exit-code comment.
- Acceptance: Each change has a test that fails without it; worker_auth_test.sh green on real Linux in hosted CI; both PowerShell hosts green; independent security review (secret-bearing path).
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P09 — Implement one mixed-fleet capacity allocator

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `supervisor/capacity/**`, `tests/capacity/**`.
- Deliverable: Acquire durable generation-bound reservations before boot/registration. Count legacy, warm/listening and cleanup-uncertain workers; enforce five total runner slots plus aggregate CPU/RAM/disk/IO and physical-host reserve.
- Acceptance: Profile counts are two live controls, Linux 0-5 and Windows 0-5, with Linux + Windows <= 5; each control's maximum is recomputed from the other (3 Linux => Windows max 2; 5 Windows => Linux 0) and 0 is valid for either. Resource allotment follows the counts per profile and the host reserve is never given away. The tray shows the two profiles as separate groups with the OS on every runner card and per-profile totals and limits next to each control (owner requirement 2026-10-19). Per-profile resource shares are a hard requirement: each runner profile gets a configurable share of host CPU/RAM and a reserved host remainder (owner example 2026-10-19: 2 Windows runners = 30 %, 3 Linux runners = 60 %, 10 % kept for the owner's desktop). Sixth worker, duplicate lease, concurrent starts, lost heartbeat, controller crash, late completion, failed reset, memory overhead and storage pressure cannot over-admit or release capacity early. Legacy pool never remains autonomous at five plus Windows.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #35 merged at `af2ad53` (accepted head `042248f`; hosted CI green; Pester 154/154 on both hosts); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Not yet wired into supervisor/providers/distro/tray (P12). `tests/capacity` entered CI with PR #41.

## P10.0 — Guest network module (shared by the Windows and Linux VM backends)

- Earliest wave: 5; prerequisites: P02.1, P09.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `supervisor/backends/network/**`, `tests/backends/network/**`.
- Deliverable: one PowerShell module for the per-profile internal switch + NAT (or per-guest private switch, per P02.1), DHCP/router guard, MAC-spoofing off, extended port ACLs (deny host vEthernet except DHCP/DNS, RFC1918, 169.254/16, 100.64/10, multicast, fe80::/10, fc00::/7, LAN IPv6 prefix, clone subnet except gateway), enhanced session and Guest Service Interface off; attach/detach/verify consumed by P10 and P11.
- Acceptance: Pester with Hyper-V cmdlet fakes; the lab negative matrix passes on a disposable guest; External/Default switch attachment refused.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P10 — Implement Windows VM backend

- Earliest wave: 5; prerequisites: P08, P09.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/windows/**`, `tests/backends/windows/**`.
- Deliverable: Implement create/boot/ready/one-job/drain/collect/reset-or-destroy/reconcile against frozen contracts using immutable base and task-owned differential/scratch disks. Use the approved guest management transport.
- Acceptance: Crash at every lifecycle boundary; discover orphan guest safely; cancellation and cleanup are idempotent. Guest Administrator cannot access host shares/control key. No slot reuse before verified guest teardown.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: PR_OPEN — PR #45 at `bd1bfdc` on `parity/p10-windows-backend` (base `f36ae7e`), authored with fakes only; no VM and no switch (P10.0/P02.1 lab gates still open); independent reviews pending.

## P11 — Implement Linux VM backend

- Earliest wave: 5; prerequisites: P08, P09.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/linux/**`, `tests/backends/linux/**`.
- Deliverable: Implement the same lifecycle for Ubuntu VM guests, isolated management access, ephemeral runner and deterministic workspace/service/process/network cleanup.
- Acceptance: Restart and cancellation recover without duplicate registration. Guest root stays inside guest boundary. A subsequent job cannot observe prior system/HOME/workspace/listener changes.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P12 — Integrate supervisor and versioned file contracts

- Earliest wave: 6; prerequisites: P10, P11.
- Pinned execution lane: Sol high; ownership: `supervisor/aap-runner-supervisor.ps1`, `supervisor/supervisor.Tests.ps1`, `supervisor/README.md`, `crates/tray/src/state.rs`, `crates/tray/src/settings.rs`.
- Deliverable: Integrate providers into existing PowerShell host task. Add compatible per-profile allocation/status, pool-wide on/off/pause/drain, generation-aware observations and legacy adoption. Update both contract sides/tests in the same PR.
- Acceptance: Profile counts are two live controls, Linux 0-5 and Windows 0-5, with Linux + Windows <= 5; each control's maximum is recomputed from the other (3 Linux => Windows max 2; 5 Windows => Linux 0) and 0 is valid for either. Resource allotment follows the counts per profile and the host reserve is never given away. The tray shows the two profiles as separate groups with the OS on every runner card and per-profile totals and limits next to each control (owner requirement 2026-10-19). Per-profile resource shares are a hard requirement: each runner profile gets a configurable share of host CPU/RAM and a reserved host remainder (owner example 2026-10-19: 2 Windows runners = 30 %, 3 Linux runners = 60 %, 10 % kept for the owner's desktop). Old settings/status read safely; unknown future schemas reject safely; mixed state and failure reporting proven with fixtures. Off/pause/resizing never cancels a running job. Rust and both PowerShell suites pass.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P13 — Package zccache guest integration

- Earliest wave: 5; prerequisites: P04, P03.
- Pinned execution lane: Sol high; ownership: `guests/cache/**`, `tests/guests/cache/**`.
- Deliverable: Package verified per-platform zccache and initialize only qualified wrappers before Actions starts. Isolate mutable daemon/index roots; use supported cache transport and daemon retention. Bound total artifact+metadata+log+temp bytes.
- Acceptance: Daemon failure and unsupported compiler modes preserve direct build correctness; no hardlink poisoning, shared mutable index assumption or raw oldest-file eviction. Cold/warm/concurrent/crash cases pass; product cache namespaces have explicit trust and retention owners.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: PR_OPEN — PR #40 at `3da64e5` on `parity/p13-zccache-guest` (base `f36ae7e`), authoring only; review fixes in progress in the attempt-1 worktree. The zccache AGPL-3.0-only compliance decision and the cache trust-class source (App permission) are pending with the owner.

## P14 — Implement Windows guest bootstrap

- Earliest wave: 6; prerequisites: P06, P10, P13.
- Pinned execution lane: Luna high; ownership: `guests/windows/**`, `tests/guests/windows/**`.
- Deliverable: Initialize fresh job identity/shell/PATH/SDK/tool-cache defaults, verified cache overlay, sensitive registration material and one-job Actions runner. Preserve hosted-style developer-environment setup rather than globally prepending every VS path.
- Acceptance: Fresh PowerShell and cmd job steps discover correct default tools; setup actions select non-default versions; no owner credential, registration material or bootstrap residue survives reset.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P15 — Implement Linux guest bootstrap

- Earliest wave: 6; prerequisites: P07, P11, P13.
- Pinned execution lane: Luna high; ownership: `guests/linux/**`, `tests/guests/linux/**`.
- Deliverable: Initialize actual Actions process HOME/temp/locale/PATH/SDK/tool-cache/user privileges/container services plus verified cache overlay and ephemeral registration.
- Acceptance: Tools installed in image remain discoverable across job steps; environment files and setup actions work. Guest sudo/package/service operations succeed; host/control-plane access is denied.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P16 — Integrate legacy distro and retire maintained sccache wiring

- Earliest wave: 7; prerequisites: P08, P13, P12.
- Pinned execution lane: Sol high; ownership: `distro/Dockerfile`, `distro/bootstrap.sh`, `distro/manager.sh`, `distro/manager.conf.example`, `distro/ephemeral-entry.sh`, `distro/labels.sh`, `distro/README.md`, `distro/staging.sha256`, `tests/manager_*.sh`, `tests/run.sh`.
- Deliverable: Install broker support, make legacy reservations coordinator-controlled and replace maintained sccache install/env/paths/whitelists/diagnostics with qualified zccache or direct compilation. Preserve legacy isolation until authorized retirement.
- Acceptance: No active sccache binary/variable/process/workflow requirement remains in maintained runtime. Bash suites and shellcheck pass on real Linux; staging hashes match. No Docker-volume deletion or live-cache purge. P19 later owns shared bootstrap/hash serially.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P17 — Implement Windows and Actions compatibility workloads

- Earliest wave: 5; prerequisites: P05.
- Pinned execution lane: Luna high; ownership: `parity/workloads/windows/**`, `parity/workloads/actions/windows/**`.
- Deliverable: Same pinned hosted/local workflows for MSVC, LLVM, SDK/resources, CMake/Ninja, Rust/native dependency/tests, .NET/MSBuild/publish, Node native addon, Python native wheel, Java and baseline-supported packaging/services/shell behavior.
- Acceptance: Each workload compiles, links, executes supported tests and produces inspected package artifacts. A missing SDK/library/env path must turn certification red. Linux containers are not assumed supported on hosted Windows. This authoring leaf closes on hosted-reference oracle validation and negative controls; final candidate execution is owned by P22/P24 after P14/P15, not claimed here.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #39 merged at `4de3674` (accepted head `b8d28da`; hosted CI run 39443851806; Pester 20/20 on both hosts; 47 definitions match hosted run 39437386210); attempt-1 cleaned and independently verified (receipt in the parity evidence store). `tests/parity/workloads` entered CI with PR #46.

## P18 — Implement Linux, Actions and xwin workloads

- Earliest wave: 5; prerequisites: P05.
- Pinned execution lane: Luna high; ownership: `parity/workloads/linux/**`, `parity/workloads/actions/linux/**`, `parity/workloads/xwin/**`.
- Deliverable: Same hosted/local Rust/C/C++/.NET/Node/Python/Java/Android/browser/container/service workload suite. Separately qualify Linux-to-Windows xwin with Clang/LLD/SDK and execute produced artifacts on native Windows.
- Acceptance: Cross compilation alone never certifies Windows execution. Positive/negative setup, package-registry/TLS, container job/action/services, cache/artifact and shell-step propagation cases fail honestly when a requirement is missing. This authoring leaf closes on hosted-reference oracle validation and negative controls; final candidate execution is owned by P22/P24 after P14/P15, not claimed here.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: MERGED_CLEANUP_REQUIRED — PR #44 merged at `4637f84` (accepted head `0284871`; hosted CI run 39455561368; 44 definitions match hosted run 39454534510); cleanup performed (worktree, local and remote branch, scratch removed) but the independent cleanup verifier has not signed, so the global barrier stays closed. Suites entered CI with PR #46.

## P19 — Integrate installer, elevation and setup contracts

- Earliest wave: 8; prerequisites: P12, P14, P15, P16.
- Pinned execution lane: Sol high; ownership: `installer/**`, `supervisor/install-supervisor.ps1`, `supervisor/helper.Tests.ps1`, `supervisor/install-helper.Tests.ps1`, `crates/tray/src/helper.rs`, `crates/tray/src/win.rs`, `distro/bootstrap.sh`, `distro/staging.sha256`, `supervisor/README.md`, `crates/tray/README.md`.
- Deliverable: Extend existing helper paths for reviewed image/backend lifecycle, ACLs, resource/disk sizing, resume and rollback preparation. Update Rust/PowerShell request tests together. Reconcile merged M4 APIs. No new elevation mechanism or implicit production upgrade.
- Acceptance: Active-pool guard, cancellation, partial install/resume, reparse/ACL/input attacks and image-manifest mismatch tested. Preserve source/key gates. All impacted suites pass; refresh staging digests. Shared bootstrap/hash paths are serialized after P16.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P20.0 — Two-profile runner controls in the tray (Windows row inert)

- Earliest wave: 2; prerequisites: P00. Pulled forward of P20 on the owner's demand (2026-10-19).
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `crates/tray/src/**`, `crates/tray/README.md`, `supervisor/aap-runner-supervisor.ps1`, `supervisor/supervisor.Tests.ps1`, `supervisor/README.md`.
- Deliverable: Linux 0–5 and Windows 0–5 controls (total ≤ 5, never 0+0, over-budget cells disabled live; Linux 0 disabled until a Windows backend exists), per-profile Each/Total and host-reserve lines, green Linux / blue Windows identity with drawn OS glyphs, OS-titled cards with coloured edge, Windows placeholder cards "Not installed", stacked per-profile usage segments in every bar and the 60-min graph, same controls on the wizard sizing page. `inbox/settings.json` stays schema 2 with optional `windows_runner_count`; `runner_count` remains the Linux count; the supervisor validates and drops the key.
- Acceptance: pure count rule tested for every combination; settings round-trip; supervisor rejects bad values and ignores Windows-only changes (Pester 5.1 + 7); cargo fmt/clippy/test green; both contract READMEs updated. Rollout: safe in any order — the tray keeps the Windows choice tray-local and never writes `windows_runner_count` to the inbox until a backend exists.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #26 merged at `f682e03` (accepted head `32f5114`), attempt-1 cleaned and independently verified.

## P20 — Implement dual-profile tray controls and diagnostics

- Earliest wave: 9; prerequisites: P19.
- Pinned execution lane: Luna high; ownership: `crates/tray/src/dashboard.rs`, `crates/tray/src/settings_panel.rs`, `crates/tray/src/wizard.rs`, `crates/tray/src/main.rs`, `crates/tray/README.md`.
- Deliverable: Expose native OS/profile, image generation, available/reserved capacity, truthful cache state, first-error remediation, image stale/quarantine state and safe on/off/pause/settings through existing inbox/helper boundaries.
- Acceptance: Profile counts are two live controls, Linux 0-5 and Windows 0-5, with Linux + Windows <= 5; each control's maximum is recomputed from the other (3 Linux => Windows max 2; 5 Windows => Linux 0) and 0 is valid for either. Resource allotment follows the counts per profile and the host reserve is never given away. The tray shows the two profiles as separate groups with the OS on every runner card and per-profile totals and limits next to each control (owner requirement 2026-10-19). Per-profile resource shares are a hard requirement: each runner profile gets a configurable share of host CPU/RAM and a reserved host remainder (owner example 2026-10-19: 2 Windows runners = 30 %, 3 Linux runners = 60 %, 10 % kept for the owner's desktop). Injected/headless tests plus authorized disposable UI proof; no tray WSL calls or secrets. Five total cap visible. Pending/resume/failure paths never show false readiness or stop active work.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P21 — Assemble and qualify immutable candidate generations

- Earliest wave: 7; prerequisites: P14, P15, P03.
- Pinned execution lane: Sol high; ownership: `tools/image-catalog/**`, `tests/image-catalog/**`, `parity/catalog/**`.
- Deliverable: Compose reviewed base images and AAP guest/cache overlays, produce final artifact hashes/inventory/provenance, secure catalog and generation metadata, retain rollback images under explicit product ownership.
- Acceptance: No credential-bearing image seals; tampered/incomplete/changed inputs cannot promote. Re-run upstream and job-context probes on final artifacts, not only pre-overlay base. Product artifacts are accounted retained outputs, not hidden leftovers.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P22 — Verify mixed-fleet integration and isolation

- Earliest wave: 10; prerequisites: P20, P21, P16, P17, P18.
- Pinned execution lane: Sol high; ownership: `parity/integration/**`.
- Deliverable: Exercise certified candidate guests under host-wide leases, actual Actions jobs, drains, cancellation, restart recovery, guest reset, network boundary, constrained disk/RAM/IO and offline dependency failure in an authorized lab.
- Acceptance: Five mixed slots and sixth denied; legacy plus new counted; no cross-job residue or host/key access; no task cancellation on graceful drain; fault at each state boundary yields truthful state. No mock-only pass for VM behavior.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P23 — Prepare consumer migrations without changing production routing

- Earliest wave: 11; prerequisites: P22.
- Pinned execution lane: Luna high; ownership: `parity/consumers/**`.
- Deliverable: Expand one exact owned preparation child per consuming repository: inventory current workflows, remove sccache coupling safely, add inert/manual-only reference and candidate fixtures, and prepare reviewed activation patches. Normal production routing remains on available legacy profiles until P27. Actual activation is a separate P27 child per repository after authorized canary availability.
- Acceptance: Preparation children are agent-merged and cleaned; selected consumer commits pass reference/candidate fixtures in the authorized lab. Negative check proves merged pre-cutover changes do not route production jobs to unavailable profiles or remove required legacy runtime cache support. Record every later P27 activation child and its exact ownership.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P24 — Issue full differential parity certificates

- Earliest wave: 12; prerequisites: P23, P22.
- Pinned execution lane: Sol high; ownership: `parity/certificates/**`.
- Deliverable: Publish complete inventory and behavioral comparison for each exact final generation, uncached/cold/warm/concurrent/reset modes, first-error evidence, accepted rig differences and certification expiry inputs.
- Acceptance: Zero missing required baseline tools and zero unexplained behavioral failures. Azure identity/hardware differences explicit. No skipped required workload or unsupported cached compiler can be silently called parity; uncached native build path must work.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P25 — Implement updates, rollback and operations

- Earliest wave: 11; prerequisites: P22, P21.
- Pinned execution lane: Sol high; ownership: `supervisor/image-maintenance/**`, `tests/image-maintenance/**`, `docs/parity/OPERATIONS.md`.
- Deliverable: Detect upstream/runner support drift, rebuild and recertify, atomically switch new admissions, quarantine failed generation, drain safely and rollback future jobs. Define cache protocol/version transitions, image/source expiry and owned retention.
- Acceptance: Update while jobs run; old jobs finish, new jobs use approved generation; corrupt candidate/upgrade crash leave last good generation; rollback works on both OSs. No silent mutable latest label or destructive cache/volume sweep.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P25.1 — Tray self-update through the existing elevated helper

- Earliest wave: 6; prerequisites: P20.0.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `crates/tray/**`.
- Deliverable: Let the tray replace its own executable through the existing elevated helper: one UAC click, no console window, no wsl.exe, no tokens in the tray; contract docs and both sides' tests updated in the same PR.
- Acceptance: cargo fmt/clippy/test green; update succeeds with the tray running or quits it itself; a bad or unsigned replacement is refused and the old build stays; independent security review of the helper verb. Overlaps crates/tray/** with P19/P20, so the coordinator serializes the claims.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P26 — Independent final security and release review

- Earliest wave: 13; prerequisites: P24, P25.
- Pinned execution lane: Sol high; ownership: `docs/parity/evidence/security/**`.
- Deliverable: An independent reviewer rechecks actual final diff, privileged guest boundary, broker/JIT secrecy/replay, management channel, artifact trust, cache isolation, allocator crash semantics, fork guards and cleanup implementation. Repair findings in new linked items and re-certify affected evidence.
- Acceptance: No unresolved blocking finding; reviewer evidence refers to exact tested commits/artifacts. Finding repairs have their own worktree, PR, merge proof and cleanup; stale certification invalidated. No real key read needed.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P27 — Owner-authorized staged rollout and recovery

- Earliest wave: 14; prerequisites: P26.
- Pinned execution lane: Sol high; ownership: `docs/parity/evidence/cutover/**`.
- Deliverable: Only after new explicit owner authorization, stage certified images and adopt/drain legacy capacity before adding a native Windows canary, then Ubuntu. Never run five legacy plus additional new workers. Record measured reserves and live parity results. Activate consumer routing only after the target profiles are available and approved; expand one exact owned activation child per repository, preserving rollback routing. P28 waits for every activation child to merge and clean.
- Acceptance: Existing jobs finish without cancellation, global cap holds through restart, native real workflows pass, rollback rehearsed. Never delete Docker volumes or benchmark data. No authorization means waiting, not completed or failed. Confirm pre-cutover normal jobs stay routable, then native-profile canary availability before activation, real production routing after activation, and rollback routing on rehearsal. Activation children remain incomplete until agent-merged and cleanup-verified.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P28 — Close the parity ledger and maintenance handoff

- Earliest wave: 15; prerequisites: P27.
- Pinned execution lane: Luna medium; ownership: `docs/parity/evidence/final/**`.
- Deliverable: Reconcile every task/consumer child, reference/candidate certificate, merge/review identity, cleanup receipt, retained product asset and update/rollback runbook. Remove all disposable planning/execution resources by their manifests and publish the verified service profile.
- Acceptance: Every required task accepted, agent-merged where applicable and CLEANUP_VERIFIED; no orphan worktree/target/process/temp artifact. Explicit product images/cache/evidence remain accounted. No deferred mandatory parity gate or unsupported claim.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.
