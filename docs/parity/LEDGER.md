# Parity implementation ledger

Revision 3 (executing since 2026-10-19; D0 authorized). Status as of 2026-11-07 (ledger reconcile, see "Reconcile - 2026-11-07 (third close)" below) on origin/main 14b652f: the COMPLETE set of close 6 is unchanged. COMPLETE additions since close 6, each cleanup receipt verified CLEAN-WITH-NOTES by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batches 2-6, 8 and 10-12): R2.1 (#103), R1.1 (#104), R1.2 (#108), P08.2 (#110), R1.3 (#112), P08.1 (#113), P05.1 (#109), P22.1 (#117), P22.2 (#118), P12.2 (#119), R1.4 (#120), P00.1 (#122) and P10.1 (#123). Coordinator PRs #111 (P17/P18 oracle refresh, batch 7), #106 and #116 (ledger PRs, batch 9) and #121 (ledger PR, batch 12) are verified too. IN_PROGRESS: P02.4 and P02.5 (contract revisions merged as #80 and #79 on 2026-10-22, cleanup verified CLEAN-WITH-NOTES 2026-11-06, lab proof and conformance work open), P10.0, P13.5, P13.5b, P16 (#99 retired the maintained sccache wiring; broker support and coordinator-controlled legacy reservations remain; P16 is also R1 step 5) and P25.1 (claimed 2026-11-07 on feat/p25-1-tray-self-update, no PR yet). PR_OPEN: P13.5c (#83). The global no-new-dispatch barrier is OPEN: every merged parity receipt and receipted coordinator PR has a verifier verdict. The claim budgets are now enforced from ledger fields: every NOT_STARTED and IN_PROGRESS task declares `tokens` (see the third close). Open PRs: #82 (P09.x hard-cap contract, needed by P10.6/P11.3), #83 (P13.5c), #84 (P02.5 Linux conformance, pester-backends failing). Live rollout of fcb04b1 done 2026-11-06; its canary is green (2026-11-07), finalize and the tray rollout of R1.4 are pending the owner. Owner decision Q1 is SUPERSEDED by the owner's 2026-11-05 runner group decision. The close-6 status follows for history.

Status as of 2026-10-22 (ledger close 6) on origin/main a55cb7b: P00, P01, P02, P02.2, P03, P03.1, P04, P04.1, P05, P06, P06.1, P06.2, P07, P07.1, P08, P09, P10, P10.2, P10.3, P11, P11.1, P11.2, P12, P13, P13.1, P13.2, P13.3, P13.4, P14, P15, P17, P18 and P20.0 are COMPLETE (P03.1, P04.1, P12 and P14 cleanup-verified 2026-10-22 by an independent read-only verifier). P13.5 and P13.5b are merged and cleanup-verified but IN_PROGRESS: they merged without an independent review, the independent post-merge review returned FIX-FIRST on both, and their remainder item P13.5c is NOT_STARTED. Every cleanup receipt in the parity evidence store (52) now carries an independent verifier verdict (pass 1 on 2026-10-22 at 02:17 CEST for P03.1, P04.1, P12, P13.5, P13.5b, P14 and coordinator PR #72; pass 2 at 03:58 CEST for coordinator PRs #65, #73 and #77), so the global no-new-dispatch barrier is OPEN; the close-4 entry that recorded #65 as verified CLEAN had no recorded evidence before pass 2. Nothing is PR_OPEN, and the contract-revision PRs #79 (P02.5) and #80 (P02.4) are open while their items stay NOT_STARTED. Wave 6 is current. States below are current; everything not listed otherwise is NOT_STARTED. ledger.json is the machine-readable dispatch/ownership source. These are proposed paths; commands and oracles are implemented by the owning task before they can certify an outcome. Every item uses the merge-and-clean lifecycle in WORKTREES.md. Only COMPLETE dependencies unlock work; merged or gate-verified alone does not.

## Owner decisions and open gates

- 2026-10-19: native Windows runner is the critical path (Windows chain first after P02); the live five-runner legacy pool is untouched until certified cutover (D5); per-profile resource shares are a hard requirement (example 30 % Windows / 60 % Linux / 10 % owner desktop); agents merge reviewed green PRs, the owner never merges; profile counts are two live controls, Linux 0-5 and Windows 0-5 with a total of at most 5.
- 2026-10-20 lab budget approved (gate D2 budget met), `E:\aap-runner` only: base generation <= 200 GB, rollback generation <= 200 GB, per-runner clone+scratch <= 60 GB, at least 15 % of the volume free; one build VM at a time with 4 vCPU and 10 GiB static RAM at the lowest scheduling weight; internal switch + NAT only. `E:\` root locked to Administrators 2026-10-20. Windows Server 2025 Evaluation ISO provided and verified.
- Partitions and volumes are never touched; only plain files inside `E:\aap-runner\` after approval.
- Interim Windows host runner approved unisolated (group `aap-win-interim`, label `windows-host-interim`); retire it when the VM profile is certified.
- Queued for the owner (details in `ledger.json` `owner_decisions_queued`); answered in the 2026-10-21/22 owner decision session, with what remains open:
  - Q1 URGENT: interim runner exposure. DECIDED: restrict the `aap-win-interim` runner group to selected repositories only and require approval for fork PRs from all outside collaborators. Open: the OWNER applies both GitHub org/repo settings; the agent token gets 403 on the runner-group and fork-approval APIs, so the current settings are UNREAD and UNAPPLIED and nothing here claims the exposure is closed; they must be applied before Q3. SUPERSEDED 2026-11-05 by the owner (`distro/README.md` runner group section and checklist, PR #101): both groups allow public repositories (`aap-crrr` serves the repositories the owner selects), and fork PR workflows on public repositories need approval for all outside collaborators, the only gate on the unisolated interim runner. This ledger has not read the settings through the API; whether Q3 still waits on anything is the owner's call.
  - Q2: zccache 1.15.6 AGPL-3.0-only. DECIDED: internal use only, never redistribute binaries or images containing it; P13 activation is unblocked on this question. Open: nothing for the licence decision (P13 shared-root activation still also needs Q3 applied and P02.3). Restated by the owner on 2026-10-26 in the body of PR #86: "AGPL is fine for internal runner images."
  - Q3: GitHub App permissions for cache trust-class lookups. DECIDED: `actions: read` + `contents: read`, only on repositories in the `aap-crrr` runner group, and only AFTER Q1 is applied. Open: the OWNER applies it; unapplied at ledger close 6, so P02.3 and cache sharing cannot rely on it yet.
  - Q4: hard VM lifetime cap. DECIDED: 6 hours for all repositories. Open: not implemented; P10.6 (Windows backend) and P11.3 (Linux backend) are NOT_STARTED (their prerequisites P10/P11 and P12 are COMPLETE); the lab proof is gated on the owner; the frozen contract still says the wall clock only flags, so a contract revision is needed first or with them. As of 2026-11-06: `docs/ROADMAP.md` R3 (owner-approved 2026-11-04) lists the P10.6 six-hour cap as remaining work; the contract revision is PR #82 (open, unmerged).
  - Q5: even-mode drain when a runner count is raised. DECIDED: accept as is. Open: nothing.
  - Q6: guest identity record (P02.5). APPROVED: an offline record in the Windows unattend/answer file and the Linux cloud-init seed (`vm_id`, `reservation_id`, `lease_generation`, expected scratch disk size/identity), Hyper-V KVP off, SMBIOS UUID rejected. Open: the contract revision is PR #79 (open, not merged), then the four conformance items (P10 WriteUnattend, P11 seed, P14, P15) and the independent security review. As of 2026-11-06: PR #79 merged at `c7ee17a` on 2026-10-22 (cleanup verified CLEAN-WITH-NOTES 2026-11-06); the Linux conformance (P11 seed, P15) is PR #84, open, pester-backends failing; the Windows side (P10 WriteUnattend, P14) has no PR.
  - Q7 (new 2026-11-07, non-blocking): confirm or raise the P22.2 generation minimums (Windows 2 CPU / 4 GiB, Linux 2 CPU / 2 GiB). The values in force are coordinator placeholders chosen with the advisor (PR #118, merged); nothing waits on the answer.
  - Q8 (new 2026-11-07, non-blocking): Authenticode code-signing for the tray (buy or provision a certificate). Until then P25.1's "unsigned replacement refused" is met by sha256 and PE/version checks; nothing waits on the answer.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #122 merged at `95ed418` (merge commit, accepted head `9791d37`, hosted CI run 42347969064 5/5 green); attempt-1 cleaned and independently verified CLEAN-WITH-NOTES (receipt in the parity evidence store, `verifier-pass-2026-11-06.md` batch 12). The claim budgets read their limits from the ledger fields and their tokens from each task's `tokens` array.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED (planned). Open input: owner decision Q3.
- Why: P13 landed without a host-side way to bind a job's trust class to the guest cache root; a bind_cache command is needed, and it is gated on the owner's GitHub App permission decision.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #74 merged at `38d813a` (branch parity/p03-1-manifest-pins, head `27405a9`; hosted CI run 39621944088 4/4 SUCCESS; independent read-only review READY): the runner-images source archives (82 Windows and 72 Ubuntu script hashes) and the Ubuntu 24.04.5 server media are pinned, both build plans regenerate fully pinned (14 profile blockers stay; docker-engine-windows-static keeps its documented null first-fetch hash as an explicit blocker). PR #78 merged at `a55cb7b` (head `27b8d0e`; hosted CI run 39686286153 4/4 SUCCESS): the pinned ubuntu-24.04.5 SHA256SUMS was GPG-verified once on 2026-10-22 (local time) in a throwaway keyring: good signature from the Ubuntu CD Image Automatic Signing Key (2012), fingerprint 8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092, cross-checked against ubuntu.com/tutorials/how-to-verify-ubuntu; the signed bytes equal the pinned kernel.org copy and its ISO line matches the pin; the ISO itself was never downloaded; the former TOFU caveat is retired and pinned by tests/images/common. Cleanup receipts P03.1-attempt-1 (PR #74) and P03.1-attempt-2 (PR #78, written by the orchestrator): cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier, who cross-checked the pinned digest, fingerprint and ISO line but did not repeat the GPG run (notes: attempt 1 has three stale time-bound statements; attempt 2 was renamed from P03.1-gpg-attempt-1 after failing validation, and the retained GPG report prints the SHA256SUMS digest with 62 characters instead of 64).
- Why: P06 and P07 real builds are refused (AAP_ScriptUnpinned) because the runner-images script hashes are null until their trees are pinned in the manifest.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #71 merged at `f80757c` (branch parity/p04-1-qualification-matrix, head `1475f98`; hosted CI run 39603900134 4/4 SUCCESS): 8 Linux -g rows (all UNQUALIFIED/direct pending the lab), matrix_revision 2, retention.md aligned with cache rule 6 revision 3, five harness fixes in both harnesses; the review must-fixes (-EncodedCommand removed from the two new test paths, security M1 poison control phase) landed in the merged head per the orchestrator's records; cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier (note: the receipt counts 14 changed files, GitHub shows 13).
- Why: P04 left Linux -g rows unqualified and retention.md requirement 4 still contradicts cache rule 6 revision 3.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE (2026-11-06) — PR #109 (branch `fix/p05-1-certify-hardening`, head `6f384cc`) merged at `16d0870` on 2026-11-06; hosted CI 5/5 on the head; receipt P05.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 8; notes: the two reviews are recorded in-session only, no registry manifest, main push CI on the merge still queued, the pin note on main is looser than the receipt's list). The harness change re-pinned the P17/P18 oracles to hosted runs 42301321135 (Linux 44/44) and 42301328046 (Windows 47/47), on the same images as the #111 pins and identical to runs 42239305519 / 42239311263 by definition id (status, exit_code and expected; command, log hashes, timestamps and the source-tree hash differ).
- Why: P05 review follow-ups: certify ignores the evidence-bundle waivers and exit_code binding, and its regex accepts a trailing newline.

## P06 — Build the native Windows image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/windows/**`, `tests/images/windows/**`.
- Deliverable: Port the pinned VS2026 upstream provisioning order to the approved local VM builder. Preserve reboots, users, environment, tool cache, services, upstream tests/software reports, sysprep and activation/source requirements.
- Acceptance: Fresh guest and actual job user pass full inventory/upstream tests; native compiler/SDK/resource discovery works. No host-specific credential or App key in image. Measure image, staging, replacement and scratch storage; do not inherit the 60 GiB Linux default.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #38 merged at `c621999` (accepted head `d0169ca`; hosted CI run 39354581645; Pester 254/254 on both hosts; mutation 53/53); attempt-1 cleaned and independently verified (receipt in the parity evidence store). No real build has run (D2 lab first); 82 upstream script hashes null until P03.1; per-test waivers and the secret-scan skip list are P06.1. `tests/images/windows` entered CI with PR #41.

## P06.1 — Per-adapter network controls, elevated-context hardening, per-test waivers and a reviewed secret-scan skip list

- Earliest wave: 6; prerequisites: P06, P02.2.
- Pinned execution lane: Sol medium (Claude: Opus medium); ownership: `images/windows/**`, `tests/images/windows/**`.
- Deliverable: Per-adapter network controls and elevated-context hardening in the Windows image builder, found by the P07 reviews. Also (carried from the original P06.1 scope): the verify phase needs failed-test names in the verify reply to apply per-test waivers, and the reviewed secret-scan skip list is extended from D2 evidence (currently only System Volume Information).
- Acceptance: Each hardening finding has a test that fails without its fix; Pester green on both hosts and in hosted CI; waivers apply only to named failed tests bound to the workload; every skip-list entry cites observed lab evidence. The skip-list extension needs a real build from the D2 lab, so that part is gated on P02.1/D2.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE: PR #52 merged at a6bf1a7; cleanup verified CLEAN. The skip-list part remains gated on a D2 lab build.

## P07 — Build the Ubuntu 24.04 VM image

- Earliest wave: 5; prerequisites: P03.
- Pinned execution lane: Luna high; ownership: `images/ubuntu-24.04/**`, `tests/images/ubuntu-24.04/**`.
- Deliverable: Build the full pinned Ubuntu 24.04 VM environment using upstream install/config/tool-cache/test/post-generation logic, with guest-only passwordless sudo, systemd and baseline container capabilities.
- Acceptance: All inventory categories and cached versions verified; fresh job shell/environment and baseline services work. No Ubuntu 26.04; Sysbox compatibility is not certified as full VM equivalence.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE: PR #49 merged at 19ac900; cleanup verified CLEAN; 5.1 builder mutation sweep 59/59. Ubuntu image suite 338/338; hosted CI 4/4. Real builds stay refused until P03.1 pins script hashes.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE (2026-11-06) — PR #113 (branch `fix/p08-1-broker-notes`, head `ce8ec37`) merged at `5df813c` on 2026-11-06; hosted CI 5/5 on the head; receipt P08.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 6; notes: the review is recorded in-session only, no registry manifest, the merged tree was never CI-tested on its own). Process deviation recorded in the receipt and confirmed by the verifier (B6.3): #113 merged 7 s after #111, before #111's cleanup was verified; both are verified now, and no cleanup consequence followed.
- Why: P08 review notes that were non-blocking: audit log location, lease-file removal on create failure, client timeout floor and an exit-code comment.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS: the contract, shared pure check (supervisor/network/AapHostNetworkCheck.psm1), shared fake (tests/common/AapHostNetworkFake.psm1) and four consumer conformance items merged in PR #58 (b7b06f6) and PR #60 (15eb4d9); rounds 1-7; cleanup verified CLEAN; suites 420/420 on pwsh 7 and Windows PowerShell 5.1; mutations 87/87. The Hyper-V module itself (switch + NAT creation, port ACL application, real Attach/Detach/Verify, lab negative matrix) is NOT_STARTED, gated on P02.1. P10.0 still needs P02.1 and P09. Coordinator cleanup receipt: evidence/coord-net-contract-attempt-1.receipt.json.

## P10 — Implement Windows VM backend

- Earliest wave: 5; prerequisites: P08, P09.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/windows/**`, `tests/backends/windows/**`.
- Deliverable: Implement create/boot/ready/one-job/drain/collect/reset-or-destroy/reconcile against frozen contracts using immutable base and task-owned differential/scratch disks. Use the approved guest management transport.
- Acceptance: Crash at every lifecycle boundary; discover orphan guest safely; cancellation and cleanup are idempotent. Guest Administrator cannot access host shares/control key. No slot reuse before verified guest teardown.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #45 merged at `2e4adb5` (accepted head `a2fc492`; hosted CI run 39485881809; Pester 212/212 on both hosts; 79 mutation checks); attempt-1 cleaned and independently verified (receipt in the parity evidence store). Never run against a real VM (P02.1 lab); network module is a seam (P10.0); no hard VM lifetime cap (owner decision Q4); hardening in P10.1. `tests/backends/windows` entered CI with PR #50.

## P10.1 — Harden the Windows VM backend after the P10 reviews

- Earliest wave: 6; prerequisites: P10.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `supervisor/backends/windows/**`, `tests/backends/windows/**`.
- Deliverable: Make the backend's tests stop leaving SY+BA-locked fixtures that only an owner self-grant can delete; harden clone measurement against files that vanish mid-walk so a transient race no longer destroys the VM; dismount a stale mount left behind.
- Acceptance: Each item has a test that fails without its fix; the suite leaves nothing that needs elevation to delete; a vanished file during clone measurement retries or fails closed without destroying a healthy VM; a stale mount is dismounted by the reconcile path; both PowerShell hosts green.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #123 merged at `14b652f` (merge commit, accepted head `bd42b31`, hosted CI run 42348355779 5/5 green); attempt-1 cleaned and independently verified CLEAN-WITH-NOTES (receipt in the parity evidence store, batch 12). The pre-existing SY+BA-locked TEMP folder `C:\Users\poslj\AppData\Local\Temp\x2d5fc1` (not from this item) is left for the owner.
- Why: P10 shipped with test fixtures that need an owner self-grant to delete, a 'clone not measurable' path that destroys on a transient race, and a stale-mount case it does not dismount.

## P11 — Implement Linux VM backend

- Earliest wave: 5; prerequisites: P08, P09.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/linux/**`, `tests/backends/linux/**`.
- Deliverable: Implement the same lifecycle for Ubuntu VM guests, isolated management access, ephemeral runner and deterministic workspace/service/process/network cleanup.
- Acceptance: Restart and cancellation recover without duplicate registration. Guest root stays inside guest boundary. A subsequent job cannot observe prior system/HOME/workspace/listener changes.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE: PR #53 merged at 01d159f, authored against fakes; cleanup verified CLEAN. Linux backend suite 334/334; hosted CI 4/4.

## P12 — Integrate supervisor and versioned file contracts

- Earliest wave: 6; prerequisites: P10, P11.
- Pinned execution lane: Sol high; ownership: `supervisor/aap-runner-supervisor.ps1`, `supervisor/supervisor.Tests.ps1`, `supervisor/README.md`, `crates/tray/src/state.rs`, `crates/tray/src/settings.rs`.
- Deliverable: Integrate providers into existing PowerShell host task. Add compatible per-profile allocation/status, pool-wide on/off/pause/drain, generation-aware observations and legacy adoption. Update both contract sides/tests in the same PR.
- Acceptance: Profile counts are two live controls, Linux 0-5 and Windows 0-5, with Linux + Windows <= 5; each control's maximum is recomputed from the other (3 Linux => Windows max 2; 5 Windows => Linux 0) and 0 is valid for either. Resource allotment follows the counts per profile and the host reserve is never given away. The tray shows the two profiles as separate groups with the OS on every runner card and per-profile totals and limits next to each control (owner requirement 2026-10-19). Per-profile resource shares are a hard requirement: each runner profile gets a configurable share of host CPU/RAM and a reserved host remainder (owner example 2026-10-19: 2 Windows runners = 30 %, 3 Linux runners = 60 %, 10 % kept for the owner's desktop). Old settings/status read safely; unknown future schemas reject safely; mixed state and failure reporting proven with fixtures. Off/pause/resizing never cancels a running job. Rust and both PowerShell suites pass.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #70 merged at `15e7f39` (branch parity/p12-supervisor-integration; PR head `b958f97` is main merged into the reviewed tip `6b96f71` to resolve the contracts README conflict; hosted CI 4/4 SUCCESS on `6b96f71` (run 39614507774), on `b958f97` (run 39635099925, which started 3 s before the merge and finished after it) and on main at `15e7f39` (run 39635120199)); backend mutation runners on pwsh 7: Linux 101/102 and Windows 85/86 killed, each survivor the Windows PowerShell 5.1-only stdin-bom check (killed on 5.1.26100.9711), a documented platform exception that is still open (PR #76 does not touch the survivor's targets, `supervisor/backends/linux/AapLinBackend.psm1` and `supervisor/backends/windows/AapWinBackend.psm1`: the two modules, their transport tests and the mutation runners are byte-identical at `15e7f39`, `c37bdec`, `680b820` and `729d3e7`; P13.5c investigates it); independent code and security review READY at the same logic per the coordinator's records; cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier after an empty leftover parity/P12 directory was removed (notes: the receipt's base_sha and reviewed_head were corrected to the git-verified values `1814b7a` (fork point) and `6b96f71` before the pass, and the merge-of-main commit `b958f97` carries the placeholder author email [EMAIL]).

## P13 — Package zccache guest integration

- Earliest wave: 5; prerequisites: P04, P03.
- Pinned execution lane: Sol high; ownership: `guests/cache/**`, `tests/guests/cache/**`.
- Deliverable: Package verified per-platform zccache and initialize only qualified wrappers before Actions starts. Isolate mutable daemon/index roots; use supported cache transport and daemon retention. Bound total artifact+metadata+log+temp bytes.
- Acceptance: Daemon failure and unsupported compiler modes preserve direct build correctness; no hardlink poisoning, shared mutable index assumption or raw oldest-file eviction. Cold/warm/concurrent/crash cases pass; product cache namespaces have explicit trust and retention owners.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #40 merged at `cec295b` (accepted head `97990b5`; hosted CI run 39486269433; Pester 134/134 on both hosts, Git Bash 168/168, hosted ubuntu-24.04 172/172); attempt-1 cleaned and independently verified (receipt in the parity evidence store). No matrix row qualified so every build is direct; shared roots default OFF; the trust source needs the App decision (Q3) and bind_cache (P02.3); t_shim_concurrent flaked on push CI (P13.1). `tests/guests/cache` entered CI with PR #50.

## P13.1 — Root-cause and fix the flaky t_shim_concurrent in the zccache guest tests

- Earliest wave: 5; prerequisites: P13.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `guests/cache/**`, `tests/guests/cache/**`.
- Deliverable: Root-cause the intermittent 'and all equal direct' failure of tests/guests/cache/zccache_test.sh t_shim_concurrent seen on hosted push CI run 39496833364; fix the shim or the test.
- Acceptance: Root cause recorded; stress-loop proof in WSL Ubuntu-24.04 (and a hosted CI rerun series) without a failure; no weakening of the 'equal direct' assertion unless the cause is shown to be the test.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE: PR #55 merged at f2a4d1b; the flaky test failure was in the test double; cleanup verified CLEAN. Cache tests 170+ / 226 pass; hosted CI 4/4.
- Why: t_shim_concurrent flaked on the first push CI run after P13 merged; PR #55 fixed the test-double bug.

## Close 4 - 2026-10-21

Merged coordinator PRs since close 3: #54 (ac34ca4, Linux backend suite wired and 3 elevated-account test fixes), #58 (b7b06f6) and #60 (15eb4d9, P10.0 network module contract and shared pure check), and #65 (b51580a, Ubuntu image suites, shellcheck globs and Pester); all cleanup verified CLEAN. Per-item merges are recorded in ledger.json and below.

| Item | Delivery state |
| --- | --- |
| P06.1 #52 a6bf1a7; P07 #49 19ac900; P11 #53 01d159f; P13.1 #55 f2a4d1b | COMPLETE; cleanup verified CLEAN |
| P07.1 #62 e4cca67; P11.1 #57 8752c0f; P13.2 #56 c27bb3e; P13.3 #59 3b06440; P10.2 and P10.3 #61 4305fc2 | COMPLETE; cleanup verified CLEAN |
| P11.2 #63 5b8ca03 | Merged; verifier pending |
| P06.2 #64 1814b7a | Merged; guest seal resets only the build adapter; Windows image suite 347/347; cleanup running |
| P13.4 #66 (branch parity/p13-4-activation-compare) | In flight; reviewed PASS, hosted CI running |

P07.1 additionally records the gzip allowlist route, removal of the docker.images requirement, plan section validation against certify.py, and named make-ssl-cert failure. P11.1 hardens relay containment, absent sequence handling, ISO read verification and unbuffered JIT writes. P13.2 binds cache trust to the default branch ref and exact-string repository id. P13.3 verifies shim delivery before success; real zccache 1.15.6 stress evidence records 9200+ calls and 0 bad outputs. P10.2 conforms the Windows backend to the network contract; P10.3 writes password/JIT payloads unbuffered.

New children and follow-ups (all NOT_STARTED; owner is coordinator): P22.1 verifies the deployed zccache daemon SHA-256 before priming; P12.1 adds a host-network watcher at most every 60 seconds during long build phases; P12.2 reconciles orphan aap-wbuild-* VMs whose build lock is not held; P10.4 ties each aap-guest-<id> adapter to its VM id; P10.5 runs P10.0 Verify with ErrorActionPreference Stop and asks the lab to confirm interface name Ethernet; P02.4 tests clone-to-clone ARP poisoning on the shared guest switch. Authored work used fakes only; no VM, vSwitch or NAT exists yet. Test suites ran on pwsh 7 and Windows PowerShell 5.1; hosted CI was 4/4 green on every merged head. P07.1 and P06.2 remain PARTIAL on the at-most-60-second running-phase network re-check until P12.1 lands. P13.3 accepted residuals remain: concurrent writers to the same -o path may interleave; Windows hardlinked outputs pass delivery check without a link-count check (COPY mode is the control); link/lld-link outputs are unchecked. Operational note: replies may remain in agent transcripts, reviewers may write findings to scratchpad files, and idle agents may need a nudge. The empty C:/c/AI_STUFF/PROGRAMMING/aap-runner-work/parity tree created by a path-translation slip at 02:41 is left for the owner to delete.

## Close 5 - 2026-10-21

Ledger corrections and additions recorded in ledger.json this close:

| Item | Delivery state |
| --- | --- |
| P11.2 #63 5b8ca03; P06.2 #64 1814b7a; P13.4 #66 c652963; P15 #68 af65183 | COMPLETE; cleanup verified CLEAN 2026-10-21 by an independent read-only verifier |
| P14 #69 61eead7 | MERGED_CLEANUP_REQUIRED; independent cleanup verifier pending |
| P12 #70; P04.1 #71; coord-ci-wiring-6 #72 | PR_OPEN; not merged |

Fixed in this close: the P11.2 and P06.2 `pr` fields previously held merge SHAs (`pull/5b8ca03`, `pull/1814b7a`) instead of PR numbers; both now point at PRs #63 and #64, and P11.2/P06.2/P13.4 are COMPLETE with cleanup verified CLEAN. P10.0 stays IN_PROGRESS (only the contract, shared pure check, shared fake and four consumer conformance items have merged; the real Hyper-V module is not written).

New follow-ups (all NOT_STARTED): P08.2 re-checks that the runner is still idle immediately before the release request in `distro/worker-auth.sh`; P22.2 records a minimum guest memory and CPU per image generation so an 8 CPU / 16 GiB host cannot admit ~2 GiB Windows guests (which cannot boot Windows Server) and P22/P24 certificates state the minimums; P02.5 is the proposed offline guest identity record written into the Windows unattend/answer file and the Linux cloud-init seed (vm_id, reservation_id, lease_generation, expected scratch disk size/identity; Hyper-V KVP off, SMBIOS UUID alternative; NOT P02.4; owner approval queued as Q6), landing as a contract revision plus four conformance items (P10 WriteUnattend, P11 seed, P14, P15); P13.5 gives zccache an empty stdin in the cache shim (`guests/cache/linux/aap-zccache.sh`, `guests/cache/windows/AapZcCache.psm1`), landing after P04.1 merges. Coordinator PR open: coord-ci-wiring-6 (#72) wires `tests/guests/linux/agent_test.sh` after the ubuntu `guest_test.sh` step, shellcheck globs for `guests/linux/*.sh` and `tests/guests/linux/*.sh`, and `tests/guests/windows` into the pester-backends Run.Path.

## P13.4 — Compare activation list ordinally

- Earliest wave: 6; prerequisites: P13.2.
- Pinned execution lane: Sol medium; ownership: `guests/cache/**`, `tests/guests/cache/**`.
- Deliverable: Compare activation list ordinally.
- Acceptance: PR #66 merged; cleanup verified CLEAN.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #66 merged at `c652963` (branch parity/p13-4-activation-compare); cleanup verified CLEAN 2026-10-21 by an independent read-only verifier.

## P08.2 — Release a worker lease only if the runner is still idle

- Earliest wave: 5; prerequisites: P08.
- Pinned execution lane: Sol medium; ownership: `distro/worker-auth.sh`, `tests/worker_auth_test.sh`.
- Deliverable: In `distro/worker-auth.sh`, re-check that the runner is still idle immediately before sending the release request, so a busy or unreadable runner keeps its lease instead of being released.
- Acceptance: A runner that turns busy (or whose status is unreadable) between the idle read and the release request is not released; worker_auth_test.sh green on real Linux in hosted CI.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE (2026-11-06) — PR #110 (branch `fix/p08-2-release-idle-recheck`, head `e666f57`) merged at `1f1988d` on 2026-11-06; hosted CI 5/5 on the head; receipt P08.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 4; notes: the review is recorded in-session only, no registry manifest).
- Why: the P12 cross-family review found the busy? re-check before releasing a runner fails OPEN on an unreadable status; the same release path is reached from worker-auth.sh.

## P13.5 — Give zccache an empty stdin in the cache shim

- Earliest wave: 6; prerequisites: P13, P04.1.
- Pinned execution lane: Sol medium; ownership: `guests/cache/linux/aap-zccache.sh`, `guests/cache/windows/AapZcCache.psm1`, `tests/guests/cache/**`.
- Deliverable: Run the zccache client with an empty/closed stdin from the cache shim on both platforms so an open stdin cannot hang the client.
- Acceptance: Each shim invocation proves an empty stdin on both platforms; a hung-stdin mutation is caught by tests/guests/cache on both PowerShell hosts and real Linux.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS — PR #75 merged at `c37bdec` (branch parity/p13-5-zccache-stdin, head `04b4ba2`; hosted CI run 39666824846 4/4 SUCCESS after two rounds that failed only pester-backends because of the test double: a scheduling-dependent ReadAsync probe that also saw the UTF-8 BOM preamble) without an independent review; the independent post-merge review (Codex gpt-6.1-sol, high, read-only, 2026-10-22) returned FIX-FIRST: HIGH a closed stdin is not necessarily empty (the preamble reaches the client on Windows PowerShell 5.1 with a UTF-8 input encoding and the merged probe accepts it; P13.5b, PR #76, addresses the normal start path), MEDIUM the Windows initialization test does not establish its advertised condition (no held-open input pipe, shared log), MEDIUM the Linux probe takes `read` exit status 1 as zero bytes so `x` then EOF passes as empty; the fixes are P13.5c, and P13.5 stays IN_PROGRESS until P13.5c lands and is independently reviewed; cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier (notes: the receipt's written time and `leases_released` list are inexact, and the four PR commits carry the placeholder author email [EMAIL]).
- Why: P04.1 found that an open stdin hangs the zccache client; land it after P04.1 merges.

## P02.5 — Guest identity record (proposed; owner approval queued)

- Earliest wave: 6; prerequisites: P02.2.
- Pinned execution lane: Sol high (Claude: Opus high); ownership: `parity/contracts/**`, `docs/parity/evidence/lab/**`.
- Deliverable: Proposed (NOT P02.4, the unrelated ARP-poisoning lab test; owner approval queued as Q6): the host writes a per-clone guest identity record OFFLINE into the Windows unattend/answer file and the Linux cloud-init seed (vm_id, reservation_id, lease_generation, expected scratch disk size/identity); the guest reads it once at first probe and binds. Hyper-V KVP stays OFF (KVP-on leaks the host name; P06 security review); SMBIOS UUID is the alternative. Implement as a contract-revision PR (contract text + schema + fixtures + validator + tests), reviewed first, then four small conformance items: P10 WriteUnattend, P11 seed, P14, P15.
- Acceptance: validate.py PASS with the new fixtures; a missing or mismatched identity record fails the first probe closed; no host-identifying data reaches the guest beyond the record fields; independent security review; gated on owner approval (Q6).
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS (2026-11-06) — owner approval Q6 recorded (2026-10-21/22); the contract revision (guest-transport revision 2) merged as PR #79 at `c7ee17a` (head `d621e9a`) on 2026-10-22; its cleanup receipt P02.5-attempt-1 was verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 1). Missing: the Linux conformance (P11 seed, P15) is PR #84, open, pester-backends failing on its head; the Windows conformance (P10 WriteUnattend, P14) has no PR; the independent security review is not recorded.
- Why: the Highs from the cross-family review need a guest-side binding of vm_id/reservation/lease_generation to the clone; KVP-on leaks the host name.

## P22.2 — Minimum guest memory and CPU per image generation (P22/P24)

- Earliest wave: 7; prerequisites: P09.
- Pinned execution lane: Sol medium; ownership: `supervisor/capacity/**`, `tests/capacity/**`.
- Deliverable: Record a minimum guest memory and CPU per image generation in the allocator inputs and refuse admission of a profile whose per-generation minimums do not fit the host after the control VM and the reserve, so the P22/P24 certificates state the minimums.
- Acceptance: An 8 CPU / 16 GiB host admits only profiles whose image-generation minimum memory/CPU fit the host reserve; a ~2 GiB Windows guest (which cannot boot Windows Server) is refused before boot, not admitted and left unbootable.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE (2026-11-07) — PR #118 (branch `fix/p22-2-generation-minimums`, head `849e43f`, base `93ed165`) merged at `20b5c2a` on 2026-11-07; hosted CI 5/5 on the head; receipt P22.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 10; notes: the review is recorded in-session only, no registry manifest, the minimums are provisional pending owner decision Q7). A guest below its image generation's minimum is refused as `minimum` before any boot. The minimums (win25-vs2026-x64 2 CPU / 4 GiB, ubuntu-24.04-x64 2 CPU / 2 GiB) are coordinator placeholders chosen with the advisor.
- Why: today an 8 CPU / 16 GiB host admits Windows guests at ~2 GiB including overhead, which cannot boot Windows Server.

## P22.1 — Verify the deployed zccache daemon before priming

- Earliest wave: 10; prerequisites: P13.3.
- Pinned execution lane: Sol medium; ownership: `supervisor/**`, `tests/**`.
- Deliverable: Verify SHA-256 of the deployed daemon (`<root>/v1.15.6/zccache-daemon[.exe]`) before priming; refuse or delete otherwise.
- Acceptance: An unexpected SHA-256 is refused or deleted before any shared cache root is primed.
- Closure: as every item. Current state: COMPLETE (2026-11-07) — PR #117 (branch `fix/p22-1-zccache-daemon-hash`, head `a9cc713`, base `16d0870`) merged at `69d977b` on 2026-11-07; hosted CI 5/5 on the head; receipt P22.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 10; notes: the review is recorded in-session only, no registry manifest, the base clone was briefly switched to another branch while the worker had uncommitted edits (a worker statement, not checkable), the installed copy was not inspected). The change landed in the cache shims (`guests/cache/**`) and the staged copy `distro/aap-zccache.sh`, not under `supervisor/**`.

## P12.2 — Reconcile orphan build VMs after a builder crash

- Earliest wave: 6; prerequisites: P09.
- Pinned execution lane: Sol medium; ownership: `supervisor/**`, `tests/**`.
- Deliverable: Reconcile orphan `aap-wbuild-*` build VMs whose build lock is not held.
- Acceptance: A crashed builder does not leave an orphan build VM attached.
- Closure: as every item. Current state: COMPLETE (2026-11-07) — PR #119 (branch `fix/p12-2-orphan-build-vms`, head `10f1960`, base `93ed165`) merged at `fc319e5` on 2026-11-07; hosted CI 5/5 on the head; receipt P12.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 10; notes: the advisor and orch-review results are recorded in-session only, no registry manifest, one sentence of the receipt was corrected after the pass, the installed supervisor was not inspected). A build VM whose lock file exists and opens exclusively is removed; a build VM with no matching lock file is left alone and reported as a WARN row (coordinator and advisor decision, the second commit). The live supervisor does not run this path while no Windows VM backend is loaded.

## Close 6 - 2026-10-22

Merged since close 5 (origin/main 61eead7 to a55cb7b; hosted CI 4/4 SUCCESS on every merged PR head, read from GitHub): #70 P12 (15e7f39), #71 P04.1 (f80757c), #72 coord-ci-wiring-6 (dc35042), #73 ledger close 5 (c0588e2), #74 P03.1 (38d813a), #75 P13.5 (c37bdec), #76 P13.5b (729d3e7), #77 coordinator .gitignore (52f9d22) and #78 P03.1 GPG (a55cb7b). Ledger corrections and additions recorded in ledger.json this close:

| Item | Delivery state |
| --- | --- |
| P14 #69 61eead7 | COMPLETE; cleanup verified CLEAN 2026-10-22 by an independent read-only verifier |
| P12 #70 15e7f39; P04.1 #71 f80757c; P03.1 #74 38d813a plus #78 a55cb7b | COMPLETE; cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier (notes below; P12 after an empty leftover directory was removed) |
| P13.5 #75 c37bdec; P13.5b #76 729d3e7 (new record) | IN_PROGRESS: merged and cleanup verified CLEAN-WITH-NOTES 2026-10-22, but both merged without an independent review, the post-merge review returned FIX-FIRST on both and the fixes are P13.5c; neither is COMPLETE |
| coord-ci-wiring-6 #72 dc35042 | merged; cleanup verified CLEAN 2026-10-22 by an independent read-only verifier |
| coordinator PRs #65 b51580a (coord-ci-wiring-5), #73 c0588e2 (ledger close 5) and #77 52f9d22 (/.symforge/ in .gitignore) | merged; cleanup verified 2026-10-22 by an independent read-only verifier in pass 2: #65 CLEAN-WITH-NOTES (its 'verified CLEAN' from close 4 had no recorded evidence before this pass), #73 CLEAN, #77 CLEAN-WITH-NOTES |
| P13.5c | NOT_STARTED (new; remainder item of P13.5b: fixes the post-merge review findings; prerequisites P13, P04.1, P11) |
| P10.6 (Windows backend), P11.3 (Linux backend) | NOT_STARTED (new; the Q4 hard 6 hour VM lifetime cap) |
| P02.4, P02.5 | NOT_STARTED (unchanged); contract-revision PRs #80 and #79 are open, not merged |

Independent cleanup verification (read-only, 2026-10-22 02:17 CEST; report `verifier-pass-2026-10-22.md` in the parity work directory; every full SHA in the verified receipts resolves to a commit): CLEAN for P14 and coord-ci-wiring-6; CLEAN-WITH-NOTES for P04.1 (the receipt counts 14 changed files, GitHub shows 13), P13.5 (the receipt's written time and `leases_released` list are inexact), P13.5b (receipt renamed from P13.5b-attempt-1 after failing validation; no registry manifest; the cleanup script also force-removed an unrelated tray-build worktree), P03.1 (attempt 1 has three stale time-bound statements; attempt 2 was renamed from P03.1-gpg-attempt-1 after failing validation, and the retained GPG report prints the SHA256SUMS digest with 62 characters instead of 64) and P12 (CLEAN-WITH-NOTES once an empty leftover directory `parity/P12/` was removed on 2026-10-22; its receipt's `base_sha` and `reviewed_head` were corrected to the git-verified `1814b7a` and `6b96f71` before the pass). The verifier did not repeat the P03.1 GPG run. It also found that six commits on main (`04b4ba2`, `98801d3`, `d278cae` and `6637d71` in P13.5, `680b820` in P13.5b and `b958f97`, the P12 merge-of-main) carry the placeholder author and committer email `[EMAIL]` instead of the required noreply identity; history cannot be repaired without rewriting main, which is forbidden, and the report suggests writing the identity from a file or the environment and rejecting `[EMAIL]` before push.

A second independent verifier pass (read-only, 2026-10-22 03:58 CEST; report `verifier-pass-2-2026-10-22.md` in the parity work directory) covered the three coordinator PRs the first pass left out: #65 (coord-ci-wiring-5) CLEAN-WITH-NOTES (the shared `parity/coord` directory was recreated empty by later items, and the receipt's tray duration is 2m45s, not 3m05), #73 (ledger close 5) CLEAN and #77 (coordinator .gitignore) CLEAN-WITH-NOTES (the PR added three lines, not one, and the owner's redundant uncommitted `.gitignore` diff in the base clone was dropped before the fast-forward, which can no longer be inspected). Close 4 recorded #65 as verified CLEAN with no evidence behind it: its receipt's verifier field read pending until this pass. All 52 cleanup receipts in the parity evidence store now carry a verifier verdict and none reads pending, which is what WORKTREES.md requires before the barrier may be open (the barrier is hand-kept: the registry directory holds manifests only).

Independent post-merge review of PRs #75 and #76 (Codex gpt-6.1-sol, high, read-only, 2026-10-22; reply `t006-p135-post-merge-sol.reply.md` in the parity work directory, comms/to-claude/read): both merged without an independent review (WORKTREES.md: agents merge after independent review) and both came back FIX-FIRST. PR #75: HIGH a closed stdin is not necessarily empty (the redirected writer's preamble reaches the client on Windows PowerShell 5.1 with a UTF-8 input encoding, and the merged probe accepts EF BB BF; PR #76 addresses the normal start path only); MEDIUM the Windows initialization test does not establish its advertised condition (no held-open input pipe; it asserts on a shared log); MEDIUM the Linux probe takes `read` exit status 1 as zero bytes, so `x` followed by EOF passes as empty. PR #76: HIGH `Process.Start` exceptions bypass the encoding restore (no `finally` around Start in `Invoke-AapZcProcess` or in the ssh-keygen start); MEDIUM the global encoding swap is unsynchronized (a second runspace can observe the temporary encoding) and the ssh-keygen start lacks the Windows PowerShell 5.1 guard the cache module has; MEDIUM the tests do not exercise the wrapped Windows PowerShell 5.1 path (the cache tests launch pwsh 7) and there is no provider test; MEDIUM its claim to close the P12 survivor is unsupported (corrected in this file and in ledger.json). WORKTREES.md says an early-merged incomplete item is preserved, cleaned and given a recovery/remainder item before dispatch reopens, and never manufactured COMPLETE, so P13.5 and P13.5b are IN_PROGRESS (the state P10.0 already uses for merged pieces of an unfinished item) and their remainder item is P13.5c.

Merge notes: P12 merged with a conflict-resolution head (`b958f97` is main merged into the reviewed tip `6b96f71`); that head's CI run started 3 seconds before the merge and finished 4/4 green afterwards, and push CI on main at `15e7f39` is 4/4 green. The backend mutation runners ran on pwsh 7 (Linux 101/102 and Windows 85/86 killed); each survivor is the Windows PowerShell 5.1-only stdin-bom check, a documented platform exception that is still open: P13.5b (PR #76, a new record) does not close it, because the survivor's targets are `supervisor/backends/linux/AapLinBackend.psm1` and `supervisor/backends/windows/AapWinBackend.psm1` and PR #76 changed neither (the two modules, their transport tests and the mutation runners are byte-identical at `15e7f39`, `c37bdec`, `680b820` and `729d3e7`); P13.5c investigates it. What P13.5b addressed is the preamble: on a UTF-8 console Windows PowerShell 5.1's redirected stdin writer put the three-byte EF BB BF preamble into the client's pipe, and its swap makes an empty stdin mean zero bytes before EOF on the normal start path, with the defects the review found still open. P13.5 (PR #75) took three CI rounds: the two failures were the test double (a scheduling-dependent ReadAsync probe that also saw the preamble), not the module. P04.1 merged with its review must-fixes landed in the head. P03.1 had two PRs: #74 pinned the runner-images archives and the Ubuntu server media in the acquisition manifest, and #78 added the GPG check below.

P03.1 GPG outcome (PR #78, head `27b8d0e`): the signature of the pinned Ubuntu 24.04.5 SHA256SUMS verified GOOD once on 2026-10-22 (local time) in a throwaway keyring, with nothing imported into any real keyring; key 'Ubuntu CD Image Automatic Signing Key (2012)', fingerprint 8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092, cross-checked against ubuntu.com/tutorials/how-to-verify-ubuntu; the signed bytes equal the pinned kernel.org copy (sha256 `728064ecf411f4ab702d9c3ca0a938ce672771424c028a1b52b2449f7eb5a068`) and the `ubuntu-24.04.5-live-server-amd64.iso` line matches the pin; the ISO itself was never downloaded. The former TOFU caveat is retired and pinned by tests/images/common.

Owner decisions Q1-Q6 were answered in the 2026-10-21/22 owner decision session (the owner queue at the top of this file and ledger.json `owner_decisions_queued`, which now carries `status`, `decided`, `answer` and `still_open`, hold each answer and what remains open): Q1 DECIDED, restrict the `aap-win-interim` runner group to selected repositories only and require approval for fork PRs from all outside collaborators, applied by the OWNER before Q3 (the settings are UNREAD and UNAPPLIED: the agent token gets 403 on those APIs); Q2 DECIDED, zccache is AGPL-3.0-only, internal use only, never redistribute binaries or images containing it, P13 activation is unblocked on this question; Q3 DECIDED, App `actions: read` + `contents: read` only on the `aap-crrr` group's repositories and only after Q1, applied by the OWNER, unapplied; Q4 DECIDED, a hard VM lifetime cap of 6 hours for all repositories (new items below); Q5 DECIDED, even-mode drain accepted as is; Q6 APPROVED, an offline record in the unattend/answer file and the cloud-init seed, Hyper-V KVP off, SMBIOS UUID rejected (contract revision PR #79, open, not merged).

P02.4 design decision (state unchanged: NOT_STARTED, lab-gated on P02.1 and the owner): L2 isolation between clones is a permanent host neighbour entry per guest (a static MAC from the range 02-A0-98-xx-xx-xx plus `New-NetNeighbor -State Permanent`) plus the source pin; PVLAN is an optional lab add-on only and the shared check keeps refusing `VlanMode` `Private`. The contract revision is PR #80 (open, not merged); its open lab questions are the permanent entry against gratuitous ARP and ARP replies, and a static MAC through Windows Setup and cloud-init.

New follow-ups (all NOT_STARTED; owner is coordinator): P10.6 (Windows backend) and P11.3 (Linux backend) enforce the Q4 cap: the supervisor stops each VM 6 hours of wall clock after its start, independent of the job and of the guest, reclaims it through the verified-teardown path, reports the job failed with an explicit reason and does not reuse the slot before verified teardown; fake-backed tests prove the cap fires at the boundary, survives a supervisor restart (the start time is persisted) and reclaims a guest that ignores shutdown; the lab proof is gated on the owner. Their prerequisites P10/P11 and P12 are COMPLETE. The frozen contract still says the wall clock only flags and never destroys (allocator.md Wall-clock rule, status-settings.md, the README) and `lease_wall_clock_hours` is 1..72, so a contract revision is needed first or with them. P10.6 and P11.3 were the next free ids in their sequences, so the P02.5 conformance items take the ids after them.

P13.5c (NOT_STARTED; owner is coordinator; branch parity/p13-5c-stdin-restore; prerequisites P13, P04.1 and P11, all COMPLETE; `remainder_of` P13.5b) fixes exactly the findings listed above (restore the encoding in a `finally`, guard and serialize the swap, test the wrapped Windows PowerShell 5.1 path and the provider, make a closed stdin empty, test the Windows initialization with a held-open input pipe, make the Linux probe reject `x` then EOF, keep counts only in the fake's log) and investigates the open P12 survivor. Its prerequisite is the merged P13.5b code, not P13.5b's COMPLETE state, and P13.5 and P13.5b stay IN_PROGRESS until P13.5c lands and is independently reviewed. The five implementation commits `6637d71`, `d278cae`, `98801d3`, `04b4ba2` (PR #75) and `680b820` (PR #76) carry the placeholder email `[EMAIL]`; history is not rewritten and P13.5c's commits use the required noreply identity.

Left untouched on purpose (their text predates the answers above): P02.3 (open input Q3), P02.5 ('proposed', SMBIOS UUID as the alternative) and P10 (declared gap 'no hard VM lifetime cap', now P10.6). Read them with the owner queue.

Fixed in this close: ledger.json `as_of`, `origin_main`, `in_flight` and `cleanup_barrier_state` had not been refreshed since close 4 and now match this status (barrier OPEN, with the verifier verdicts named); the two PENDING owner lines in `decisions` (zccache licence, App permissions) became the dated answers; P12's stale evidence (PR draft, mutation runners not yet run) and P14's 'origin/main head' wording were corrected, and P12 now carries the git-verified `base_sha` (`1814b7a`, the fork point) and `reviewed_head` (`6b96f71`, the tip before the conflict-resolution merge); the close-4 'verified CLEAN' of coordinator PR #65 was replaced by the pass-2 verdict, and coordinator PR #73 now has its own row.

## P13.5b — An empty stdin means zero bytes before EOF on every console

- Earliest wave: 6; prerequisites: P11, P13.5.
- Pinned execution lane: Sol medium; ownership: `guests/cache/windows/AapZcCache.psm1`, `supervisor/backends/linux/AapLinBackend.HyperV.psm1`, `tests/guests/cache/**`.
- Deliverable: Windows PowerShell 5.1 builds the redirected stdin writer at Process.Start from the console input encoding and flushes that encoding's preamble (EF BB BF on a UTF-8 console) into the client's pipe, so a closed stdin is not empty. Swap in a BOM-less console input encoding for the Start only, then restore the caller's, in `Invoke-AapZcProcess -Capture` and in the Linux backend's HyperV ssh-keygen start; the fake zccache fails any byte before EOF (exit 7) and logs what it saw; the stdin Describe runs on a UTF-8 console as the regression.
- Acceptance: An empty stdin means zero bytes before EOF on every console: the fake zccache client reads zero bytes and then EOF on a UTF-8 console and any byte fails the call; tests/guests/cache green on both PowerShell hosts and in hosted CI.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS — PR #76 merged at `729d3e7` (branch parity/p13-5b-stdin-no-preamble, head `680b820`; hosted CI run 39680138282 4/4 SUCCESS) without an independent review; the independent post-merge review (Codex gpt-6.1-sol, high, read-only, 2026-10-22) returned FIX-FIRST: HIGH `Process.Start` exceptions bypass the encoding restore (no `finally` in `Invoke-AapZcProcess` or the ssh-keygen start), MEDIUM the global swap is unsynchronized and the ssh-keygen start lacks the Windows PowerShell 5.1 guard, MEDIUM the tests miss the wrapped Windows PowerShell 5.1 path and the provider; the fixes are P13.5c, and P13.5b stays IN_PROGRESS until P13.5c lands and is independently reviewed. This PR does not close the P12 stdin-bom survivor (its targets are untouched, see the P12 closure); the cleanup receipt's scope sentence claiming it did was unsupported. Cleanup verified CLEAN-WITH-NOTES 2026-10-22 by an independent read-only verifier (notes: the receipt (coord-p13-5b) was renamed from P13.5b-attempt-1 after failing validation, there is no registry manifest, the cleanup script also force-removed an unrelated tray-build worktree, and commit `680b820` carries the placeholder author email [EMAIL]). The receipt records no local test counts.
- Why: P13.5's CI rounds showed that on a UTF-8 console Windows PowerShell 5.1's redirected stdin writer emits the console input encoding's preamble into the client's pipe at Start, so a client that reads its stdin sees three bytes before EOF instead of an empty stdin.

## P13.5c — Fix the defects the independent review found in the P13.5 and P13.5b stdin work

- Earliest wave: 6; prerequisites: P13, P04.1, P11; remainder of P13.5b.
- Pinned execution lane: Sol high; ownership: `guests/cache/windows/AapZcCache.psm1`, `supervisor/backends/linux/AapLinBackend.HyperV.psm1`, `tests/guests/cache/**`, `tests/backends/linux/**`, `tests/backends/windows/Invoke-AapWinMutations.ps1`.
- Deliverable: Fix exactly the findings of the independent post-merge review of PRs #75 and #76 (Codex gpt-6.1-sol, high, read-only, 2026-10-22): (1) HIGH, PR #76: restore the console input encoding in a `finally` around `Process.Start` in `Invoke-AapZcProcess` (`guests/cache/windows/AapZcCache.psm1`) and in the Linux backend's HyperV ssh-keygen start (`supervisor/backends/linux/AapLinBackend.HyperV.psm1`), so a failed start (missing executable, denied launch) cannot leave the caller's encoding changed; (2) MEDIUM, PR #76: give the ssh-keygen swap the same Windows PowerShell 5.1 guard as the cache module and serialize cooperating starters across save, swap, start and restore, so a second runspace cannot observe the temporary encoding, and document the concurrency constraint; (3) MEDIUM, PR #76: tests that exercise the wrapped Windows PowerShell 5.1 path (the cache tests launch pwsh 7 today), both console encodings and failed starts, plus a provider test with a harmless fake executable; (4) HIGH, PR #75: a closed stdin must be empty: suppress the preamble and require zero bytes (the merged probe accepted the BOM; PR #76 fixes only the normal start path); (5) MEDIUM, PR #75: test the Windows initialization separately in a child whose input pipe stays open and assert its own probe records; (6) MEDIUM, PR #75: make the Linux probe (`tests/guests/cache/fakes/fake-zccache`) read one byte explicitly and reject any byte instead of taking `read` exit status 1 as zero bytes; (7) LOW: the fake writes process metadata and stdin hex to disk, keep counts only. Also investigate and record why the P12 mutation survivor (stdin-bom: the tagged conditions at `supervisor/backends/linux/AapLinBackend.psm1` line ~873 and `supervisor/backends/windows/AapWinBackend.psm1` line ~805, replaced by `$false` in `tests/backends/linux/Invoke-AapLinMutations.ps1` and `tests/backends/windows/Invoke-AapWinMutations.ps1`) survives under pwsh 7; PR #76 does not touch those modules, so the survivor is still open, and a code change in them needs an ownership revision.
- Acceptance: Every finding has a test that fails on the pre-change code (heads `04b4ba2` and `680b820`; main `729d3e7`) and passes after the fix: a failed `Process.Start` with a preamble-bearing original encoding leaves that encoding unchanged; cooperating starters never observe or restore a foreign encoding; the wrapped Windows PowerShell 5.1 path is exercised under UTF-8 and non-UTF-8 consoles; the initialization probe fails without the production fix; the Linux probe rejects `x` followed by EOF; the P12 survivor is either killed by a new check or recorded as a documented platform exception with evidence; tests/guests/cache and the backend suites are green on both PowerShell hosts and real Linux in hosted CI; independent review READY at the exact head, because P13.5 and P13.5b merged without one. Commits use the required special-place-administrator noreply identity.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: PR_OPEN (2026-11-06) — PR #83 (branch parity/p13-5c-stdin-restore, head `6df256a`, hosted CI 4/4 SUCCESS); the independent review READY at that head is not recorded; owner is the coordinator. P13.5c is the remainder item of the early-merged P13.5b (and P13.5): its prerequisite is the merged P13.5b code, not P13.5b's COMPLETE state, and P13.5 and P13.5b stay IN_PROGRESS until P13.5c lands and is independently reviewed.
- Why: The independent post-merge review (Codex gpt-6.1-sol, high, read-only, 2026-10-22; replies `t005-ledger6-sol` and `t006-p135-post-merge-sol` in the parity work directory) returned FIX-FIRST on PRs #75 and #76, which merged without an independent review. Also recorded here: the five implementation commits `6637d71`, `d278cae`, `98801d3`, `04b4ba2` (PR #75) and `680b820` (PR #76) carry the literal placeholder author and committer email [EMAIL] instead of the required noreply identity; history is not rewritten.

## P10.6 — Enforce the 6-hour hard VM lifetime cap in the Windows backend

- Earliest wave: 7; prerequisites: P10, P12.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/windows/**`, `tests/backends/windows/**`.
- Deliverable: Windows backend part of owner decision Q4: the supervisor enforces a 6 hour wall-clock cap per VM, independent of the job and of the guest. At the cap the VM is stopped, reclaimed through the verified-teardown path, and the job is reported failed with an explicit reason; the slot is not reused before verified teardown. A guest reply and the runner's GitHub status (online, busy) never extend or reset the cap, and its start time is persisted, not held only in memory.
- Acceptance: Fake-backed tests prove the cap fires at the boundary, survives a supervisor restart (the start time is persisted, not held in memory) and reclaims a guest that ignores shutdown; the Windows backend suite is green on both PowerShell hosts and in hosted CI. The lab proof is gated on the owner.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED. Its contract revision (P09.x, allocator.md L1-L10) is PR #82, open and unmerged; `docs/ROADMAP.md` R3 lists this item as remaining work.
- Why: owner decision Q4 (2026-10-21/22), a hard VM lifetime cap of 6 hours for all repositories. P10 declared the gap 'no hard VM lifetime cap' (supervisor/backends/windows/INTEGRATION.md request 4, supervisor/broker/INTEGRATION.md F4): a guest that holds its runner credential can keep GitHub reporting its runner online and busy, so a heartbeat-quarantined slot may never be freed. Needs a contract revision first or with this item: allocator.md (Wall-clock rule), status-settings.md and the README still say the wall clock only flags and never destroys, backend-lifecycle.md has no lifetime-cap result, and `lease_wall_clock_hours` (1..72, default 6) must be reconciled with the fixed 6 hour cap.

## P11.3 — Enforce the 6-hour hard VM lifetime cap in the Linux backend

- Earliest wave: 7; prerequisites: P11, P12.
- Pinned execution lane: Sol high; ownership: `supervisor/backends/linux/**`, `tests/backends/linux/**`.
- Deliverable: Linux backend part of owner decision Q4: the supervisor enforces a 6 hour wall-clock cap per VM, independent of the job and of the guest. At the cap the VM is stopped, reclaimed through the verified-teardown path, and the job is reported failed with an explicit reason; the slot is not reused before verified teardown. A guest reply and the runner's GitHub status (online, busy) never extend or reset the cap, and its start time is persisted, not held only in memory.
- Acceptance: Fake-backed tests prove the cap fires at the boundary, survives a supervisor restart (the start time is persisted, not held in memory) and reclaims a guest that ignores shutdown; the Linux backend suite is green on both PowerShell hosts and in hosted CI. The lab proof is gated on the owner.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: NOT_STARTED. Its contract revision (P09.x) is PR #82, open and unmerged.
- Why: owner decision Q4 (2026-10-21/22), a hard VM lifetime cap of 6 hours for all repositories. The Linux backend inherits the P10 gap (supervisor/backends/linux/INTEGRATION.md request 3: hard VM lifetime cap, as the Windows twin's request 4): a guest that holds its runner credential can keep GitHub reporting its runner online and busy, so a heartbeat-quarantined slot may never be freed. Same contract dependency as P10.6.

## P14 — Implement Windows guest bootstrap

- Earliest wave: 6; prerequisites: P06, P10, P13.
- Pinned execution lane: Luna high; ownership: `guests/windows/**`, `tests/guests/windows/**`.
- Deliverable: Initialize fresh job identity/shell/PATH/SDK/tool-cache defaults, verified cache overlay, sensitive registration material and one-job Actions runner. Preserve hosted-style developer-environment setup rather than globally prepending every VS path.
- Acceptance: Fresh PowerShell and cmd job steps discover correct default tools; setup actions select non-default versions; no owner credential, registration material or bootstrap residue survives reset.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #69 merged at `61eead7` (branch parity/p14-windows-guest-bootstrap, head `6e7b37a`; hosted CI run 39585329014 4/4 SUCCESS); cleanup verified CLEAN 2026-10-22 by an independent read-only verifier.

## P15 — Implement Linux guest bootstrap

- Earliest wave: 6; prerequisites: P07, P11, P13.
- Pinned execution lane: Luna high; ownership: `guests/linux/**`, `tests/guests/linux/**`.
- Deliverable: Initialize actual Actions process HOME/temp/locale/PATH/SDK/tool-cache/user privileges/container services plus verified cache overlay and ephemeral registration.
- Acceptance: Tools installed in image remain discoverable across job steps; environment files and setup actions work. Guest sudo/package/service operations succeed; host/control-plane access is denied.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #68 merged at `af65183` (branch parity/p15-linux-guest-bootstrap); cleanup verified CLEAN 2026-10-21 by an independent read-only verifier.

## P16 — Integrate legacy distro and retire maintained sccache wiring

- Earliest wave: 7; prerequisites: P08, P13, P12.
- Pinned execution lane: Sol high; ownership: `distro/Dockerfile`, `distro/bootstrap.sh`, `distro/manager.sh`, `distro/manager.conf.example`, `distro/ephemeral-entry.sh`, `distro/labels.sh`, `distro/README.md`, `distro/staging.sha256`, `tests/manager_*.sh`, `tests/run.sh`.
- Deliverable: Install broker support, make legacy reservations coordinator-controlled and replace maintained sccache install/env/paths/whitelists/diagnostics with qualified zccache or direct compilation. Preserve legacy isolation until authorized retirement.
- Acceptance: No active sccache binary/variable/process/workflow requirement remains in maintained runtime. Bash suites and shellcheck pass on real Linux; staging hashes match. No Docker-volume deletion or live-cache purge. P19 later owns shared bootstrap/hash serially.
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS (2026-11-06) — PR #99 merged at `03ae663` (head `91d6fbf`, 2026-11-05, owner decision 2026-11-04) replaced the maintained sccache wiring (manager, entrypoint, image, distro README) with the `guests/cache` zccache integration, every compiler direct until a pair is qualified; PR #100 (`3ec4cbf`) checks for no sccache at image acceptance. Missing: broker support in the distro, coordinator-controlled legacy reservations (roadmap R1 step 5), the P02 security review M1 threat-model correction, a parity cleanup receipt and independent verification.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: COMPLETE — PR #44 merged at `4637f84` (accepted head `0284871`; hosted CI run 39455561368; 44 definitions match hosted run 39454534510); attempt-1 cleaned (worktree, local and remote branch, scratch removed) and independently verified CLEAN. Suites entered CI with PR #46.

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
- Closure: independent verification/review at exact head, agent merge, durable evidence and independently verified cleanup receipt. Current state: IN_PROGRESS — claimed 2026-11-07; worktree on `feat/p25-1-tray-self-update` at `14b652f`, no commits and no PR yet. Until owner decision Q8 (Authenticode certificate) is answered, "unsigned replacement refused" is met by sha256 and PE/version checks.
- Why: Replacing the tray executable today needs the owner to quit it and swap by hand; the existing elevated helper can do it with one UAC click and no console.

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

## R2.1 — Report the interim Windows runner (roadmap R2, slice 1)

- Prerequisites: P12, P20.0 (COMPLETE). Ownership: `parity/contracts/status-settings.md`, `status-v5.schema.json`, `validate.py` and fixtures, `supervisor/aap-runner-supervisor.ps1` and its tests, `crates/tray/src/{state,settings_panel,dashboard}.rs`.
- Deliverable: status-settings revision 4: the Windows profile reports `backend: windows-host` with `host_runner` (`online`, `busy`, `stopped`) while the interim runner is installed and no Windows VM backend is loaded; the supervisor detects it read-only (logon task, listener and worker processes); the tray names it and its state with one warning line. Report only: no start or stop, no JIT registration (later R2 slices).
- Closure: as every item. Current state: COMPLETE (2026-11-06) — PR #103 (branch `feat/windows-host-backend`, head `5b55b9f`) merged at `279eed4` on 2026-11-06; receipt R2.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 2; notes: stale base-clone statements, no registry manifest, the review recorded in-session only). PR #107 (receipt item and branch patterns widened) merged 2026-11-06 at `5309a62`; the receipt validates with origin/main's validator.

## R1.1 — Tiered Linux pool contract and tray (roadmap R1, steps 1 and 4)

- Prerequisites: P12, P20.0 (COMPLETE); owner brief R1 (2026-11-04). Ownership: `parity/contracts/status-settings.md`, `settings-v4.schema.json`, `status-v5.schema.json`, `validate.py` and fixtures, `distro/README.md` (label lines only), `crates/tray/**`.
- Deliverable: status-settings revision 5: settings schema 4 (`linux_light_count` 0..10, `linux_heavy_count` 0..2 instead of `runner_count`), status slots carry `tier` with fixed tier slot numbers and 17-slot maxima while schema 4 is applied; the tray's Light | Heavy count picker, compact always-drawn Linux cards (disabled slots grey) and painted tier icons, writing schema 4 only when a stored schema 4 file or a fresh `status.v5.json` allows it. Manager (step 2) and supervisor (step 3) tiers are separate items.
- Closure: as every item. Current state: COMPLETE (2026-11-06) — PR #104 (branch `feat/tray-tiers`, head `3bc41c4`) merged at `b5c946b` on 2026-11-06; receipt R1.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 2; same notes as R2.1). PR #107 merged 2026-11-06 at `5309a62`; the receipt validates with origin/main's validator.

## R1.2 — Manager runs the heavy and light Linux tiers (roadmap R1, step 2)

- Prerequisites: R1.1 (COMPLETE). Ownership: `distro/{manager,bootstrap,evidence,labels}.sh`, `distro/README.md`, `distro/staging.sha256`, `parity/contracts/status-settings.md`, `tests/manager_*_test.sh`.
- Deliverable: the distro manager runs two Linux tiers, heavy 0..2 and light 0..10, each with its own labels, limits and slot numbering, reading settings schema 4 and writing the tiered status slots of R1.1.
- Closure: as every item. Current state: COMPLETE (2026-11-06) — PR #108 (branch `feat/manager-tiers`, head `a6c184c`) merged at `b531a1f` on 2026-11-06; hosted CI 5/5 on the head; receipt R1.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 3; notes: the review is recorded in-session only, no registry manifest, main push CI on the merge still queued, the live install copy not inspected).

## R1.3 — Supervisor applies settings schema 4 and the tray mirrors the reservation rule (roadmap R1, step 3)

- Prerequisites: R1.1 (COMPLETE). Ownership: `supervisor/aap-runner-supervisor.ps1` and its README and tests, `parity/contracts/{status-settings.md,settings-v4.schema.json,validate.py,README.md}` and fixtures, `crates/tray/src/{settings,settings_panel}.rs`, `crates/tray/README.md`.
- Deliverable: the supervisor validates and applies settings schema 4 (tiered Linux pool) and keeps reading older files; the tray mirrors the supervisor reservation rule and refuses schema 4 tiers whose reservations exceed the memory total.
- Closure: as every item. Current state: COMPLETE (2026-11-06) — PR #112 (branch `feat/supervisor-schema-4`, head `7c8aea7`) merged at `fcb04b1` on 2026-11-06; hosted CI 5/5 on the head; receipt R1.3-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 5; notes: the review, one MEDIUM finding fixed in `7c8aea7`, is recorded in-session only; no registry manifest; main push CI on the merge still queued; the live install copy not inspected). This is the commit rolled out live on 2026-11-06 (see "Reconcile - 2026-11-07").

## R1.4 — Tray shows what each runner is doing and its occupancy (owner regression report 2026-11-07)

- Prerequisites: R1.3 (COMPLETE). Ownership: `crates/tray/src/{dashboard,state}.rs`, `crates/tray/README.md`.
- Deliverable: each runner card shows, while busy, its repo, job and run link and its own CPU and memory occupancy (the per-slot `cpu_cores`/`mem_gib` the manager already samples); the pool Cores/Memory/Disk bars show real samples instead of "no sample"; the tier tiles stay.
- Why: the owner, verbatim 2026-11-07: "this GUI is a regression. I need to see what each runner is doing and their occupancy" (the R1.1 compact tiles dropped per-runner activity and usage). Queued after the current work, as the owner asked.
- Closure: as every item. Current state: COMPLETE (2026-11-07) — PR #120 (branch `feat/r1-4-runner-occupancy`, head `d35cc9b`, base `20b5c2a`) merged at `1759b63` on 2026-11-07; hosted CI 5/5 on the head; receipt R1.4-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07 by an independent read-only verifier (`verifier-pass-2026-11-06.md` (parity work directory), batch 11; notes: the review and the local test counts are recorded in-session only, no registry manifest, the installed tray binary was not inspected). Root cause: the tile layout inherited the grid's horizontal layout (a layout panic reproduced with the fix reverted). Only `crates/tray/src/dashboard.rs` and the tray README changed. The installed tray still has the bug until the owner approves a tray rollout.

## Reconcile - 2026-11-06

Brings this file and ledger.json from close 6 (origin/main a55cb7b) to origin/main b5c946b. Read from `git log origin/main`, `gh pr view` and the parity evidence store.

| Item | Delivery state |
| --- | --- |
| P02.5 #79 c7ee17a | IN_PROGRESS: contract revision merged 2026-10-22; receipt P02.5-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06; Linux conformance PR #84 open (pester-backends failing); Windows conformance and security review not started |
| P02.4 #80 79d1feb | IN_PROGRESS: contract revision 2 merged 2026-10-22; receipt P02.4-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06; lab proof gated on P02.1 and the owner |
| coordinator PR #81 437ce96 (ledger close 6) | merged; receipt coord-ledger-close-6-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06 |
| P16 #99 03ae663 | IN_PROGRESS: sccache retirement merged; broker support, coordinator-controlled reservations, receipt and verification missing |
| P13.5c #83 | PR_OPEN: CI 4/4 green, independent review not recorded |
| R2.1 #103 279eed4; R1.1 #104 b5c946b | COMPLETE: receipts R2.1-attempt-1 and R1.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06; they validate once PR #107 merges |
| P10.6, P11.3 | NOT_STARTED; contract revision PR #82 open |

Barrier: OPEN. The independent read-only verifier pass `verifier-pass-2026-11-06.md` (parity work directory) signed all five receipts CLEAN-WITH-NOTES: batch 1 P02.4-attempt-1 (#80), P02.5-attempt-1 (#79) and coord-ledger-close-6-attempt-1 (#81); batch 2 R2.1-attempt-1 (#103) and R1.1-attempt-1 (#104). The R receipts depend on PR #107 (open), which widens the cleanup-receipt item and branch patterns; origin/main's validator still rejects them. No merged parity item lacks a verifier verdict.

Merged outside the parity worktree lifecycle (no parity receipts; not ledger items except where named): #88 PRODUCT.md, #89 systemd-analyze test, #90 docs/ROADMAP.md, #91 job containers under `--init`, #92 jq, #93 Node.js 26.13.0, #94 runner 2.338.2, #95 Rust 1.99.1, #96 pool-core limits crate, #98 runner image check workflow, #99 (P16 part), #100 image acceptance, #101 runner group settings docs, #102 one clock authority, #103 (R2.1), #104 (R1.1). Closed unmerged: #85, #86, #87 (2026-11-06, stale or superseded) and #97 (superseded by #99). PR #105 (CI on the owner's runners) is open. From #88 onward, CI-wiring PRs (#105 included) are not ledger items and get no coordinator receipt; a reconcile does not flag them.

Owner decisions: Q1 SUPERSEDED by the owner on 2026-11-05 (public repositories allowed on both groups, fork approval for all outside collaborators; `distro/README.md`, PR #101). Q2 restated 2026-10-26 (PR #86 body). Q4 reaffirmed by `docs/ROADMAP.md` R3 (2026-11-04); contract PR #82 open. Q3 has no record of being applied, and its precondition (the old Q1 answer) needs restating by the owner. Q5 unchanged. Q6's contract merged (#79); conformance open.

NOT_STARTED items whose prerequisites are all COMPLETE (the barrier is open): P00.1, P02.1 (lab gate D2 and the owner), P02.3 (owner Q3), P05.1, P08.1, P08.2, P10.1, P10.6 and P11.3 (contract PR #82 first), P12.2, P21, P22.1, P22.2, P25.1.

## Reconcile - 2026-11-07

Brings this file and ledger.json from origin/main b5c946b to origin/main 16d0870. Read from `git log origin/main`, `gh pr view`, the parity evidence store and `verifier-pass-2026-11-06.md` (parity work directory), batches 3-8.

| Item | Delivery state |
| --- | --- |
| R1.2 #108 b531a1f | COMPLETE (new item): receipt R1.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06, batch 3 |
| P08.2 #110 1f1988d | COMPLETE: receipt P08.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06, batch 4 |
| R1.3 #112 fcb04b1 | COMPLETE (new item): receipt R1.3-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06, batch 5 |
| P08.1 #113 5df813c | COMPLETE: receipt P08.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06, batch 6; merged 7 s after #111, before #111's cleanup was verified (deviation recorded in the receipt, confirmed accurate) |
| coordinator PR #111 31b2712 (P17/P18 oracle refresh) | merged; receipt coord-oracle-refresh-2026-11-attempt-1 verified CLEAN-WITH-NOTES 2026-11-06, batch 7. GitHub rolled its hosted images to 20261101.360.1 (Linux) and 20261103.298.1 (Windows); CI had stayed green on the stale oracles because `check_hosted_run` only compares against the recorded run. The oracles are re-pinned to runs 42239305519 (Linux 44/44) and 42239311263 (Windows 47/47) |
| P05.1 #109 16d0870 | COMPLETE: receipt P05.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 8. The harness change re-pinned the P17/P18 oracles to runs 42301321135 and 42301328046, identical by definition id to the #111 pins |

Counts (ledger.json tasks): 70 items (68 on 2026-11-06 plus R1.2 and R1.3): 40 COMPLETE (was 35), 6 IN_PROGRESS (P02.4, P02.5, P10.0, P13.5, P13.5b, P16), 1 PR_OPEN (P13.5c), 23 NOT_STARTED (was 26).

Barrier: OPEN. The verifier pass signed every receipt that was pending or missing: batch 3 R1.2 (#108), batch 4 P08.2 (#110), batch 5 R1.3 (#112), batch 6 P08.1 (#113), batch 7 coordinator #111, batch 8 P05.1 (#109), on top of batches 1 and 2 of the first reconcile. Cleanup-receipt schema fixes #107 and #115 are merged, so all of these receipts validate with origin/main's validator. The 7 s deviation (#113 over #111) is recorded; both receipts are verified.

Rule: CI-wiring PRs (#114, the `ci-hosted` label and concurrency group) and cleanup-receipt schema fixes (#107, #115) are coordinator support, not ledger items, and get no receipt.

Live rollout (2026-11-06): the owner chose "Both halves now" and the rollout of fcb04b1 ran at about 22:46-23:15 CET: supervisor 20F51C69..., tray C2E3CFFE..., distro scripts and runner image sha256:954816e4546b. `status.v5` now lists `settings_schemas` 1,2,4. The canary job and the finalize step are still pending.

Owner rules recorded 2026-11-06: the resource cap is 90% of CPU, RAM and disk (supersedes 97%); the interim Windows runner now runs at Idle priority; zero visible terminal windows.

Owner decisions: unchanged from the 2026-11-06 reconcile (Q1 SUPERSEDED, Q2 restated, Q3 unapplied, Q4 contract PR #82 open, Q5 unchanged, Q6 conformance open).

NOT_STARTED items whose prerequisites are all COMPLETE (the barrier is open): P00.1, P02.1 (lab gate D2 and the owner), P02.3 (owner Q3), P10.1, P10.6 and P11.3 (contract PR #82 first), P12.2, P21, P22.1, P22.2, P25.1. Off the queue since 2026-11-06: P05.1, P08.1 and P08.2 (COMPLETE).

Remaining blockers:
- P02.1 (the lab proof, gate D2 and the owner) blocks P10.0 and P02.4, and through P10.0 blocks P10.4, P10.5 and P12.1.
- P16 is R1 step 5 (the allocator adopts the Linux pool as its first backend) and is IN_PROGRESS: broker support and coordinator-controlled legacy reservations remain. P19 waits on P16, P22 waits on P16 (and on P20 and P21), and the chain P20 (via P19), P23, P24, P25, P26, P27 and P28 waits behind them. Nothing waits on R1 step 4: the tray work is in R1.1, COMPLETE.
- P13.5 stays IN_PROGRESS until its remainder P13.5c (#83, open, CI green, independent review not recorded) lands; P13.5b needs P13.5 COMPLETE.
- P10.6 and P11.3 are ready but their contract revision #82 is unmerged; P02.5's Linux conformance #84 has pester-backends failing and its Windows side has no PR.
- Pending on the live install: the canary job and finalize for the 2026-11-06 rollout.

## Reconcile - 2026-11-07 (second close)

Brings this file and ledger.json from origin/main 16d0870 to origin/main 1759b63. Read from `git log origin/main`, `gh pr view`, the parity evidence store and `verifier-pass-2026-11-06.md` (parity work directory), batches 9-11.

| Item | Delivery state |
| --- | --- |
| P22.1 #117 69d977b | COMPLETE: receipt P22.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 10 |
| P22.2 #118 20b5c2a | COMPLETE: receipt P22.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 10. The generation minimums are coordinator placeholders chosen with the advisor; owner confirmation queued as Q7 |
| P12.2 #119 fc319e5 | COMPLETE: receipt P12.2-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 10. Build VMs with no matching lock file are left alone (WARN), by coordinator and advisor decision |
| R1.4 #120 1759b63 | COMPLETE: receipt R1.4-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 11. Root cause: the tile layout inherited the grid's horizontal layout; the installed tray still has the bug until the owner approves a tray rollout |
| coordinator PR #106 30f99a2 (ledger reconcile 2026-11-06) | merged; receipt coord-ledger-reconcile-2026-11-06-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 9 |
| coordinator PR #116 93ed165 (ledger close 2026-11-07) | merged; receipt coord-ledger-close-2026-11-07-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 9 |

Counts (ledger.json tasks): 71 items (the 70 of the previous section plus R1.4, queued at the 2026-11-07 close): 44 COMPLETE (was 40), 6 IN_PROGRESS (P02.4, P02.5, P10.0, P13.5, P13.5b, P16), 1 PR_OPEN (P13.5c), 20 NOT_STARTED (was 24).

Barrier: OPEN. The verifier pass signed every receipt that was pending: batch 9 coordinator #106 and #116, batch 10 P22.1 (#117), P22.2 (#118) and P12.2 (#119), batch 11 R1.4 (#120), on top of batches 1-8. This close is itself a coordinator PR; its receipt is written after it merges.

Live (2026-11-07): the canary on the new runner image is green (Frontend, DB Integration and DB install succeeded; Security Audit fails on RustSec advisories in the canary repository, as it did on the old image). The owner set 2 heavy + 10 light runners at 02:04 CET. Pending the owner: the rollout finalize (needs the pool Off) and the tray rollout of R1.4.

Owner decisions: Q7 new and OPEN (confirm or raise the P22.2 generation minimums, Windows 2 CPU / 4 GiB and Linux 2 CPU / 2 GiB; non-blocking). Q1-Q6 unchanged from the 2026-11-07 reconcile.

Ready queue (NOT_STARTED items whose prerequisites are all COMPLETE; the barrier is open): P00.1, P02.1 (lab gate D2 and the owner), P02.3 (owner Q3), P10.1, P10.6 and P11.3 (contract PR #82 first), P21, P25.1. Off the queue since the previous section: P12.2, P22.1 and P22.2 (COMPLETE). The other 12 NOT_STARTED items wait on unfinished prerequisites: P12.1, P10.4 and P10.5 on P10.0; P19 on P16; P20 on P19; P22 on P16, P20 and P21; P23 on P22; P24 on P22 and P23; P25 on P21 and P22; P26 on P24 and P25; P27 on P26; P28 on P27.

Remaining blockers:
- P02.1 (the lab proof, gate D2 and the owner) blocks P10.0 and P02.4, and through P10.0 blocks P10.4, P10.5 and P12.1.
- P16 is R1 step 5 (the allocator adopts the Linux pool as its first backend) and is IN_PROGRESS: broker support and coordinator-controlled legacy reservations remain. P19 waits on P16, P22 waits on P16 (and on P20 and P21), and the chain P20 (via P19), P23, P24, P25, P26, P27 and P28 waits behind them.
- P13.5 stays IN_PROGRESS until its remainder P13.5c (#83, open, CI green, independent review not recorded) lands; P13.5b needs P13.5 COMPLETE.
- P10.6 and P11.3 are ready but their contract revision #82 is unmerged; P02.5's Linux conformance #84 has pester-backends failing and its Windows side has no PR.
- Pending on the live install: the rollout finalize for the 2026-11-06 rollout and the tray rollout of R1.4, both the owner's call.

## Reconcile - 2026-11-07 (third close)

Brings this file and ledger.json from origin/main 1759b63 to origin/main 14b652f. Read from `git log origin/main`, `gh pr view`, the parity evidence store and `verifier-pass-2026-11-06.md` (parity work directory), batch 12.

| Item | Delivery state |
| --- | --- |
| P00.1 #122 95ed418 | COMPLETE: receipt P00.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 12. The cleanup gate is hardened and the claim budgets are real; the receipt's follow-up (tokens inert until ledger tasks declare them) is closed by the tokens below |
| P10.1 #123 14b652f | COMPLETE: receipt P10.1-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 12. A pre-existing SY+BA-locked TEMP folder (`C:\Users\poslj\AppData\Local\Temp\x2d5fc1`, not from this item) is left for the owner |
| coordinator PR #121 16c1839 (ledger close 2026-11-07, second) | merged; receipt coord-ledger-close-2026-11-07b-attempt-1 verified CLEAN-WITH-NOTES 2026-11-07, batch 12 |
| P25.1 | IN_PROGRESS: claimed on `feat/p25-1-tray-self-update` (worktree at 14b652f, no commits, no PR). Owner decision Q8 queued |

Counts (ledger.json tasks): 71 items: 46 COMPLETE (was 44), 7 IN_PROGRESS (P02.4, P02.5, P10.0, P13.5, P13.5b, P16, P25.1), 1 PR_OPEN (P13.5c), 17 NOT_STARTED (was 20).

Barrier: OPEN. The verifier pass signed every receipt that was pending: batch 12 coordinator #121, P00.1 (#122) and P10.1 (#123), on top of batches 1-11. This close is itself a coordinator PR; its receipt is written after it merges.

Owner decisions: Q8 new and OPEN (Authenticode code-signing certificate for the tray; until then P25.1's "unsigned replacement refused" is met by sha256 and PE/version checks; non-blocking). Q7 is still open; Q1-Q6 unchanged.

Ready queue (NOT_STARTED items whose prerequisites are all COMPLETE; the barrier is open): P02.1 (lab gate D2 and the owner), P02.3 (owner Q3), P10.6 and P11.3 (contract PR #82 first), P21. Off the queue since the previous section: P00.1 and P10.1 (COMPLETE) and P25.1 (IN_PROGRESS). The other 12 NOT_STARTED items wait on unfinished prerequisites: P12.1, P10.4 and P10.5 on P10.0; P19 on P16; P20 on P19; P22 on P16, P20 and P21; P23 on P22; P24 on P22 and P23; P25 on P21 and P22; P26 on P24 and P25; P27 on P26; P28 on P27.

### Claim tokens (P00.1 budgets, enforced from the ledger)

`tools/parity-work` takes a worker slot plus the `tokens` its ledger task declares at claim. The limits are the ledger fields `max_concurrent_workers` 3, `max_compile_heavy` 2, `max_full_test_suites` 1 and (new) `max_io_heavy` 1; an unknown token is refused at import. A token stays held until the item's leases are released (COMPLETE), so a HOLD or a merged, uncleaned item still counts. Tokens: `compile` builds Rust or other compile-heavy work; `suite` needs a full test suite run for its acceptance; `io` is image build, VM/VHD work, large artifact acquisition or authorized-lab work. Every NOT_STARTED and IN_PROGRESS task declares them; COMPLETE tasks do not, and P13.5c (PR_OPEN, already past its claim) is not tagged. The tags are a conservative judgment from each deliverable and ownership, revisable by a ledger edit while an item is NOT_STARTED (the gate refuses a revision once it has left NOT_STARTED).

| Item | Tokens | Rationale |
| --- | --- | --- |
| P02.1 | io | authorized-lab VM work (PowerShell Direct, hvsocket, network matrix); no test suite |
| P02.3 | (none) | contract text and fixtures checked by validate.py only |
| P02.4 | io | ARP-poisoning lab test on guest VMs |
| P02.5 | suite | conformance items (P10 WriteUnattend, P11 seed, P14, P15) run the backends Pester suites; the contract part is validate.py only |
| P10.0 | suite, io | Pester with Hyper-V fakes plus the lab negative matrix on a disposable guest |
| P10.4 | suite | supervisor/backends code change, full backends and supervisor suites |
| P10.5 | suite, io | module Verify change (suite) and a lab confirmation of the answer-file interface name (VM) |
| P10.6 | suite | Windows backend suite on both PowerShell hosts and hosted CI; the lab proof is gated on the owner and is not in the acceptance |
| P11.3 | suite | Linux backend fake-backed tests plus the backend suite |
| P12.1 | suite | supervisor/** and tests/** change, full Pester suites |
| P13.5 | suite | tests/guests/cache on both PowerShell hosts and real Linux |
| P13.5b | suite | tests/guests/cache and the Linux backend tests on both PowerShell hosts |
| P16 | suite | bash suites and shellcheck on real Linux; no image build is required by the acceptance |
| P19 | compile, suite | Rust helper/win.rs changes (cargo) and the PowerShell installer suites; "all impacted suites pass" |
| P20 | compile, suite | tray crate changes: cargo build, clippy and test, plus the Pester request tests |
| P21 | suite, io | tools/image-catalog tests and building or hashing candidate image artifacts |
| P22 | io | mixed-fleet integration with real guests in the authorized lab; no mock-only pass |
| P23 | io | consumer fixtures are exercised in the authorized lab |
| P24 | io | cold/warm/concurrent differential runs on final guests in the lab |
| P25 | suite, io | tests/image-maintenance suite and rebuild/recertify/rollback of image generations |
| P25.1 | compile, suite | crates/tray changes: cargo fmt, clippy and test, plus the helper request tests |
| P26 | (none) | independent review only |
| P27 | io | stages certified images and runs native canary workflows; owner-authorized |
| P28 | (none) | documentation closure |

Remaining blockers:
- P02.1 (the lab proof, gate D2 and the owner) blocks P10.0 and P02.4, and through P10.0 blocks P10.4, P10.5 and P12.1.
- P16 is R1 step 5 (the allocator adopts the Linux pool as its first backend) and is IN_PROGRESS: broker support and coordinator-controlled legacy reservations remain. P19 waits on P16, P22 waits on P16 (and on P20 and P21), and the chain P20 (via P19), P23, P24, P25, P26, P27 and P28 waits behind them.
- P13.5 stays IN_PROGRESS until its remainder P13.5c (#83, open, CI green, independent review not recorded) lands; P13.5b needs P13.5 COMPLETE.
- P10.6 and P11.3 are ready but their contract revision #82 is unmerged; P02.5's Linux conformance #84 has pester-backends failing and its Windows side has no PR.
- P25.1 owns `crates/tray/**`, which overlaps P19 and P20; the claim gate refuses an overlapping lease, so only one of them is claimed at a time.
- Pending on the live install: the rollout finalize for the 2026-11-06 rollout and the tray rollout of R1.4, both the owner's call.
