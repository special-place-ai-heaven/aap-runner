# Parity implementation ledger

Revision 3 (executing since 2026-10-19; D0 authorized). States below are current; everything not listed otherwise is NOT_STARTED. `ledger.json` is the machine-readable dispatch/ownership source. These are proposed paths; commands and oracles are implemented by the owning task before they can certify an outcome. Every item uses the merge-and-clean lifecycle in [WORKTREES.md](WORKTREES.md). Only `COMPLETE` dependencies unlock work; merged or gate-verified alone does not.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P02 — Freeze architecture and shared contracts

- Earliest wave: 3; prerequisites: P01.
- Pinned execution lane: Sol high; ownership: `parity/contracts/**`, `docs/parity/ARCHITECTURE.md`.
- Deliverable: Specify immutable image/catalog, host-wide resource lease, backend lifecycle, guest bootstrap, auth/JIT transport, cache qualification, status/settings compatibility, evidence and cleanup schemas. Prove management transport feasibility in an explicitly authorized disposable lab before backend fan-out.
- Acceptance: Independent security review; concrete schema examples and negative fixtures; no missing interface decision delegated to two workers. Preserve App key custody in existing control distro. PR20 is merged and reconciled before consumers depend on its helper APIs.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P03 — Implement verified artifact acquisition

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Luna high; ownership: `images/common/**`, `tests/images/common/**`.
- Deliverable: Download and retain reviewed upstream install inputs with hashes, provenance, licenses/redistribution restrictions and bounded retry; support offline staging. Do not pipe remote installers into a shell or silently float versions.
- Acceptance: Corrupt input, expired/changed upstream installer, interrupted publication and unavailable source reject the candidate. Unreproducible inputs remain explicit blockers, not omitted packages.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P04 — Qualify zccache 1.15.6 interfaces and platforms

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `parity/cache/qualification/**`, `tests/parity/cache/qualification/**`.
- Deliverable: Use zackees/zccache tag 1.15.6 and versioned documentation. Verify Linux musl evidence, Windows artifacts, Rust, GCC/Clang, clang-cl, cl.exe/link.exe, response files, paths, daemon/retention and unsupported invocation behavior.
- Acceptance: Uncached/cold/warm compiler exit codes and artifacts agree; deliberate errors remain errors; unsupported/unqualified modes run direct compilers. Windows archive availability alone is not a pass. No sccache fallback.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P05 — Build differential certification harness

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Luna high; ownership: `tools/parity-certify/**`, `tests/parity-certify/**`.
- Deliverable: Produce allowlisted machine-readable job-process inventory, environment/capability probes, reference/local comparison, first-causal-error classification and evidence bundles. Canonicalize only documented machine-specific differences.
- Acceptance: Remove a non-default cached version, alter PATH order or SDK variable, skip a workload, mismatch source/action/image SHA or forge a green log: comparison fails. Inventory and behavioral results cannot substitute for each other.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P06 — Build the native Windows image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/windows/**`, `tests/images/windows/**`.
- Deliverable: Port the pinned VS2026 upstream provisioning order to the approved local VM builder. Preserve reboots, users, environment, tool cache, services, upstream tests/software reports, sysprep and activation/source requirements.
- Acceptance: Fresh guest and actual job user pass full inventory/upstream tests; native compiler/SDK/resource discovery works. No host-specific credential or App key in image. Measure image, staging, replacement and scratch storage; do not inherit the 60 GiB Linux default.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P07 — Build the Ubuntu 24.04 VM image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/ubuntu-24.04/**`, `tests/images/ubuntu-24.04/**`.
- Deliverable: Build the full pinned Ubuntu 24.04 VM environment using upstream install/config/tool-cache/test/post-generation logic, with guest-only passwordless sudo, systemd and baseline container capabilities.
- Acceptance: All inventory categories and cached versions verified; fresh job shell/environment and baseline services work. No Ubuntu 26.04; Sysbox compatibility is not certified as full VM equivalence.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P08 — Implement protected registration and management transport

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `supervisor/broker/**`, `distro/worker-auth.sh`, `tests/worker_auth_test.sh`, `tests/broker/**`.
- Deliverable: Keep App signing/key use root-only in the existing control distro; expose a fixed bounded lease/profile operation. Prefer verified one-use JIT config; never describe a reusable registration token as one-use. Deliver sensitive material through the qualified management channel without argv, logs, inbox or golden-image persistence.
- Acceptance: Expired/replayed/stale lease, arbitrary command/path, malformed request, cross-guest request, reparse transport and unavailable broker produce no registration. Secret-marker tests prove absence in logs, artifacts, state and guest images.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P09 — Implement one mixed-fleet capacity allocator

- Earliest wave: 4; prerequisites: P02.
- Pinned execution lane: Sol high; ownership: `supervisor/capacity/**`, `tests/capacity/**`.
- Deliverable: Acquire durable generation-bound reservations before boot/registration. Count legacy, warm/listening and cleanup-uncertain workers; enforce five total runner slots plus aggregate CPU/RAM/disk/IO and physical-host reserve.
- Acceptance: Profile counts are two live controls, Linux 0-5 and Windows 0-5, with Linux + Windows <= 5; each control's maximum is recomputed from the other (3 Linux => Windows max 2; 5 Windows => Linux 0) and 0 is valid for either. Resource allotment follows the counts per profile and the host reserve is never given away. The tray shows the two profiles as separate groups with the OS on every runner card and per-profile totals and limits next to each control (owner requirement 2026-10-19). Per-profile resource shares are a hard requirement: each runner profile gets a configurable share of host CPU/RAM and a reserved host remainder (owner example 2026-10-19: 2 Windows runners = 30 %, 3 Linux runners = 60 %, 10 % kept for the owner's desktop). Sixth worker, duplicate lease, concurrent starts, lost heartbeat, controller crash, late completion, failed reset, memory overhead and storage pressure cannot over-admit or release capacity early. Legacy pool never remains autonomous at five plus Windows.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P10 — Implement Windows VM backend

- Earliest wave: 5; prerequisites: P08, P09.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/windows/**`, `tests/backends/windows/**`.
- Deliverable: Implement create/boot/ready/one-job/drain/collect/reset-or-destroy/reconcile against frozen contracts using immutable base and task-owned differential/scratch disks. Use the approved guest management transport.
- Acceptance: Crash at every lifecycle boundary; discover orphan guest safely; cancellation and cleanup are idempotent. Guest Administrator cannot access host shares/control key. No slot reuse before verified guest teardown.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P18 — Implement Linux, Actions and xwin workloads

- Earliest wave: 5; prerequisites: P05.
- Pinned execution lane: Luna high; ownership: `parity/workloads/linux/**`, `parity/workloads/actions/linux/**`, `parity/workloads/xwin/**`.
- Deliverable: Same hosted/local Rust/C/C++/.NET/Node/Python/Java/Android/browser/container/service workload suite. Separately qualify Linux-to-Windows xwin with Clang/LLD/SDK and execute produced artifacts on native Windows.
- Acceptance: Cross compilation alone never certifies Windows execution. Positive/negative setup, package-registry/TLS, container job/action/services, cache/artifact and shell-step propagation cases fail honestly when a requirement is missing. This authoring leaf closes on hosted-reference oracle validation and negative controls; final candidate execution is owned by P22/P24 after P14/P15, not claimed here.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

## P19 — Integrate installer, elevation and setup contracts

- Earliest wave: 8; prerequisites: P12, P14, P15, P16.
- Pinned execution lane: Sol high; ownership: `installer/**`, `supervisor/install-supervisor.ps1`, `supervisor/helper.Tests.ps1`, `supervisor/install-helper.Tests.ps1`, `crates/tray/src/helper.rs`, `crates/tray/src/win.rs`, `distro/bootstrap.sh`, `distro/staging.sha256`, `supervisor/README.md`, `crates/tray/README.md`.
- Deliverable: Extend existing helper paths for reviewed image/backend lifecycle, ACLs, resource/disk sizing, resume and rollback preparation. Update Rust/PowerShell request tests together. Reconcile merged M4 APIs. No new elevation mechanism or implicit production upgrade.
- Acceptance: Active-pool guard, cancellation, partial install/resume, reparse/ACL/input attacks and image-manifest mismatch tested. Preserve source/key gates. All impacted suites pass; refresh staging digests. Shared bootstrap/hash paths are serialized after P16.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED.

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
