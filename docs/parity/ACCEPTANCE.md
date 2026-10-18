# Parity acceptance and certification

This is the test contract for future P01/P05 tooling and implementation PRs. No
candidate has been certified by this planning work. Commands/providers not yet
implemented are deliverables, not existing tools or checks claimed to have passed.

## Reference and comparison method

P01 captures a real GitHub-hosted job's Set up job image identity, runner version,
architecture, upstream image release/source and exact workflow/source/action SHAs
for each initial profile. P05 runs the same fixtures with matching project commands
on the frozen AAP candidate. A moving label cannot recover an arbitrary historical
hosted image. If hosted rollout changes the reference, take a new reference and
baseline revision; do not compare against unrelated versions and call it parity.

Preserve a complete versioned manifest for every upstream inventory category:
installed tools/defaults, alternate tool-cache versions, SDKs/frameworks, shells,
services, package managers, container components, environment/configuration and
upstream image tests. Each required entry has a source location, version/selection
rule, probe, responsible task and result. A missing category, skipped upstream test
or unavailable installer is a blocker, not an unreported exception. Diffs distinguish
installed vs selected vs callable vs behaviorally tested. Pin installer hashes and
provenance; do not trust a package display name or mutable download URL alone.

Use allowlisted, redacted environment observations from the actual Actions job
process and child processes. Never dump a complete environment, registry hive,
credential store or database configuration: upstream images can contain credentials.
Compare PATH order, discovery and selections as well as versions. Normalize only
documented variable values such as per-job workspace IDs, temporary roots and VM
addresses. Preserve meaningful ordering, permissions, exit status and ABI differences.

Reference and candidate run the same deterministic success and deliberate-failure
fixtures. Pass means the observed outcome matches the fixture's explicit oracle;
deliberate compiler errors and nonzero exits are successful negative evidence when
expected. A passing reference with failing candidate blocks certification. A reference
that does not match its oracle is invalid evidence; investigate the fixture or
baseline and rerun both. Unknown, timeout, skipped and blocked remain distinct from pass.

## Required coverage

| Area / owner | Positive and negative proof |
| --- | --- |
| Baseline/provenance — P01/P03/P06/P07/P21 | Every inventory category resolved; all applicable upstream image tests pass on final sealed generation. Tampered downloads, missing installer, expired source URL and invalid catalog signature/hash fail closed. Record Windows media/activation and redistribution constraints before acquisition. |
| Windows environment — P06/P14/P17 | Native Windows Server job, hosted-equivalent user privileges, cmd/Windows PowerShell/pwsh/bash behavior, default-user/system environment, registry/SDK discovery, native paths/quoting/long paths and symlink behavior. Developer shell setup matches hosted use; globally adding every compiler to PATH is not accepted. |
| Windows builds — P17 | x64 MSVC cl/link, clang-cl/lld-link, supported CMake generators/MSBuild/Ninja, Rust msvc compile/link/test, .NET build/test/publish and pinned inventory language/package-manager fixtures. Exercise Windows SDK/UCRT/resources, debug symbols, system libraries and native execution. Include x86/other installed supported targets and actual consumer features selected by P01. Missing header/library/compiler is an explicit failure. |
| Linux environment/builds — P07/P15/P18 | Ubuntu 24.04 shell and sudo semantics, GCC/Clang/LLD, glibc/musl, CMake/Ninja/pkg-config/OpenSSL and other inventory dependencies; Rust, .NET, JVM, Node, Python, Go and all remaining inventory categories with their selected versions. Build, link, execute tests and package through Actions. No Ubuntu 26.04. |
| xwin enhancement — P18 | Independently acquired/pinned Clang/LLD, Windows SDK/CRT and cross target, reproducible build and link, then execute the artifact on native Windows. This does not substitute for Windows native fixtures. |
| Actions service — P05/P17/P18/P22 | checkout incl. LFS/submodules; setup actions select default and alternate cached versions and install an uncached version; cache restore/save and artifacts round-trip; permissions/GITHUB_ENV/GITHUB_PATH/outputs; cancellation, timeout, retry, post-job cleanup and command exit propagation. Pin action SHAs and use declared repo secrets only in authorized jobs. |
| Containers/services — P06/P07/P17/P18/P22 | All container/service behavior supported by the selected hosted profile, including Linux Docker build/run, service discovery, DNS/ports and image pulls. Windows must match its baseline's supported container behavior; do not invent hosted Windows job-container support. Prove required nested virtualization/networking in the authorized lab. |
| Dependency acquisition — P03/P17/P18/P22 | Cold and warm package acquisition through each baseline ecosystem, HTTPS trust stores/proxy defaults/DNS, archives and executable permissions; actionable offline/404/checksum/cert failure. Exercise setup action downloads outside the preinstalled set. Do not suppress dependency failures to obtain green checks. |
| Privilege/isolation — P02/P08/P10/P11/P22/P26 | Guest admin/sudo can install dependencies but cannot obtain App/controller/owner credentials or mutate the host/another guest/base image. Host shares, management transport, network rules and cache boundaries tested using synthetic secrets. Malformed/replayed/oversized broker requests and hostile guest responses rejected. Images and logs contain no registration material. |
| Lifecycle/reset — P08/P10/P11/P12/P22 | One job per disposable generation; job completion/failure/cancel/guest crash/host reboot reconciles exactly once. Next guest cannot observe files, services, identities or credentials planted by the previous job. No reuse of an altered base. Lost heartbeat retains capacity until teardown/reconciliation proof. |
| Capacity/host protection — P09/P12/P22 | Concurrent legacy + Windows + Linux admissions never exceed five or aggregate CPU/RAM/disk budgets; include idle/warm and uncertain guests plus VM overhead. Stress admission race, boot failure, stale lease and cleanup failure. Measure actual enforcement and host headroom/IO under load, not just matching config fields; fail if required isolation or limits cannot be enforced by the selected provider. |
| Cache — P04/P13/P16/P22 | Qualified per-platform zccache compiler matrix; disabled/cold/warm results equivalent; compile errors and exit codes unchanged; debug/PDB/incremental/linking/response files/path-with-spaces exercised. Concurrent jobs, daemon restart, corruption/poisoning and quota pressure cannot return wrong outputs. Unqualified modes compile directly. |
| Consumer migration — P01/P23/P27 | Enumerate all in-scope repositories/workflows and their real failing features first; exact preparation and later activation children per repository. Pre-cutover merged preparation leaves normal production routing unchanged and cannot remove cache support required by the live legacy generation. Use inert/manual-only lab fixtures. After available authorized canary profiles, activate correct OS/profile routing; no fork execution on shared self-hosted group, inherited sccache coupling or patches masking missing tools in the final state. Same selected consumer commit green on reference and candidate; prove rollback routing. |
| Installer/tray — P19/P20 | Fresh/resumed/failing install and upgrade/rollback paths in disposable lab; strict helper verb/argument validation; existing elevation and key boundary maintained. Checklist rows checking/met/unmet/blocked, exact remediation, five-second and after-Fix recheck, Next only when all met, two-second auto advance; injected pure checks unit-tested. Drive actual UI without starting the owner's installed tray. |
| Image update/rollback — P21/P25/P27 | Bad/incomplete update rejected; verified catalog promotion atomic; new admissions use new generation, running jobs finish old generation; rollback rehearsal restores known-good behavior without deleting shared volumes or interrupting live jobs. Disk capacity includes old/new/base/clone/staging overlap. |
| Cleanliness — P00/every item | Full WORKTREES.md success/negative suite; exact final head accepted and agent-merged, owned artifacts absent, independent receipt persisted, global barrier open before next claim. |

Representative fixtures above are a floor. The complete pinned inventory and real
consumer census determine the final test list; a green Rust/C++ subset does not
certify untested inventory categories. GPU, ARM, macOS and additional OS versions
are separate profiles requiring their own capabilities/baselines/certification.
Do not advertise unsupported profiles because this rig can cross-compile one target.

P17/P18 close after fixture authoring, hosted-reference oracle validation and
negative controls. Their final candidate execution depends on guest integration
and belongs to P22/P24. Likewise, provider simulation tests do not substitute for
actual Actions guest/lifecycle proof after P14/P15. No earlier authoring task claims
runtime parity before those dependencies exist.

## zccache decision record

P04 must verify release archive provenance/checksum and extracted binary identity
for Linux and Windows independently. Use the owner's 1.15.6 musl binary as a candidate
with its recorded hash, preserving its benchmark directory. Compare the pinned
feature matrix with observed behavior; native MSVC/link integration is partial in
that reference. Unsupported CUDA or unqualified compiler modes remain uncached.
No renamed sccache executable, sccache-format reuse or sccache fallback is allowed.

Record compiler/linker/tool versions and invocation forms for each supported cache
mode, cold/warm/disabled timings, hits/misses/bypass, full bytes consumed and output
equivalence. A warm build must include an actual hit, verified from sanitized
telemetry; a green build alone does not prove caching. Binary hashes may vary for
nonreproducible timestamps; use reproducible fixtures or documented semantic/ABI
comparison and native tests, never waive unexplained output changes.

Install/runtime discovery must work from the same actual job process, including
Rust wrapper invocation and compiler selection. Validate daemon ownership, indexed
retention/quota API, restart and multi-process safety. Include metadata, temp and
logs in disk accounting. Use isolated trust roots and safe copy/reflink defaults;
mutable cross-trust/hardlink reuse stays disabled until poisoning proof passes.
P16 migrates manager/image variables, wrappers, health/status, quotas, docs and
tests; P23 prepares removal of consumer-side sccache coupling and P27 activates it
with the corresponding runtime generation. Keep the old runtime generation
as an explicit rollback asset until approved cutover; do not mutate it in planning.

## Evidence, review and completion

Each accepted result records task/contract revision, exact Git heads/action SHAs,
reference and candidate image identities/hashes, resolved inputs, fixture IDs,
OS/compiler versions, test command, start/end, exit status, oracle, sanitized
artifact references and independent verifier. Include deliberate-failure results.
Retain compact structured reports, not private raw logs or entire build trees.

Required checks follow changed surfaces: tray fmt/clippy/test; supervisor/installer
Pester on Windows PowerShell 5.1 and pwsh 7; distro self-checks/bash suite and
shellcheck 0.11 warning level on an authorized separate Linux environment. Refresh
staging.sha256 when its documented inputs change. Never run these by invoking the
live WSL distro. Mock/unit tests prove logic; actual disposable VM/job/UI tests prove
the product. Report blocked live tests accurately and leave their gates incomplete.

P24 produces one certificate per exact final image/profile containing complete
inventory reconciliation, behavioral/consumer/cache results and explicit allowed
infrastructure differences. P26 independently challenges security, evidence and
omissions; repairs get tracked child PRs, cleanup and affected recertification.
No required build/environment behavior can be waived while retaining a parity claim.
P27 requires the owner's separate live authorization and a rehearsed rollback.
P28 closes only after both profiles, consumer children, rollout, review and every
cleanup receipt are accepted. Plan completion is not implementation completion.
