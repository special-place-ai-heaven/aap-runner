# Claude Code handover: GitHub runner parity

Prepared 2026-10-18 for continuation on 2026-10-19. Repository:
`C:\AI_STUFF\PROGRAMMING\aap-runner`.

**Read this fully, then the linked implementation plan and contracts. The next
engineering task is to implement the parity ledger, starting at P00. Parity has
been planned and reviewed; none of its 29 implementation items is complete.**

## What the owner wants and why this plan exists

The owner wants these runners to offer the same build service as GitHub-hosted
runners, with the rig's resource controls and caching enhancements. Repeated builds
driven by LLMs have failed on missing dependencies, native toolchains and environment
configuration. A concrete example was Windows xwin work missing clang-cl and other
build essentials. Merely having an image, Rust or a Windows SDK has not been enough.

The key realization is that the physical host being Windows 11 does not make its
WSL/container jobs Windows jobs. Existing jobs execute in Linux. Native Windows
builds need a Windows execution environment, including MSVC/Clang tooling, libraries,
SDK selection, shells and the environment visible to the actual Actions job process.
Adding a cross-compiler alone cannot demonstrate native Windows compatibility.

GitHub's service comes from an OS image plus provisioning scripts, installed and
selected tool versions, tool caches, privileges, user configuration, services,
network/package acquisition, the Actions runner and a fresh machine lifecycle.
The plan exists to reproduce and verify that complete system, rather than repeatedly
patching individual missing packages or telling consuming projects to work around it.

The owner supplied a report explaining this distinction. Read its original local
copy, without modifying or committing it:

`C:\Users\poslj\Downloads\Custom-Runner-Build-Reliability-Report-2026-10-18.md`

The scope is broad build parity for explicitly certified profiles. Do not quietly
reduce it to a handful of Rust/C++ probes. Conversely, do not promise every OS,
architecture, hardware accelerator or possible project dependency without its own
baseline and evidence. Inventory coverage plus real same-source workflow execution
defines what is supported.

## Read these in order

All repository links below resolve from this file in the project root.

1. [CLAUDE.md](CLAUDE.md), plus the harness-loaded global/project instructions.
   There was no repository `AGENTS.md` on disk at the handover snapshot; global
   AGENTS instructions were supplied in the conversation. Do not assume its absence
   relaxes any safety rule repeated here.
2. **[The implementation plan: docs/parity/PLAN.md](docs/parity/PLAN.md).**
   Absolute path: `C:\AI_STUFF\PROGRAMMING\aap-runner\docs\parity\PLAN.md`.
3. [Machine-readable task ledger](docs/parity/ledger.json),
   [worker briefs](docs/parity/LEDGER.md),
   [acceptance and certification](docs/parity/ACCEPTANCE.md),
   [worktree and cleanup contract](docs/parity/WORKTREES.md), and
   [independent planning review](docs/parity/REVIEW.md).
4. [Original installer handover](docs/HANDOVER.md),
   [tray product brief](docs/tray-launcher-plan.md),
   [tray UI design](docs/tray-dashboard-design.md), and
   [the initial parity audit](docs/github-runner-parity-audit.md).
   These supply history; their old milestone/commit descriptions are not the current
   implementation state. In particular, M4 is merged and the new parity plan corrects
   the audit's generic Windows 2025/VS2022 baseline reference.
5. All three versioned contracts:
   [distro/README.md](distro/README.md),
   [supervisor/README.md](supervisor/README.md),
   [crates/tray/README.md](crates/tray/README.md).

The handoff skill also points a fresh session to the owner's AI OS index, if needed:
`C:\AI_STUFF\PROGRAMMING\company\AI-OS-Wiki\00-Index\CLAUDE.md`.
Read the files it actually names under their applicable scope. It does not override
this repository's hard boundaries or authorize touching the Obsidian vault.

## Verified repository state at handover

The base before this handover document was written was `main` at
`14a5fcef6d5c20e16e9bd69b41783ac984c1961b`, equal to freshly fetched `origin/main`.
The handover's own documentation PR will add later history; inspect the current
branch and remote tomorrow rather than resetting back to this snapshot.

| Work | State and evidence |
| --- | --- |
| M4 first-run wizard | [PR #20](https://github.com/special-place-ai-heaven/aap-runner/pull/20) merged at `47a8ca689547d0a1f960d5c994a7a0ce8767d127`; feature head `4c3071a25bab3f7a7110c623bfd2fc0d3cea5d50`. |
| Parity planning package | [PR #21](https://github.com/special-place-ai-heaven/aap-runner/pull/21) merged at `14a5fcef6d5c20e16e9bd69b41783ac984c1961b`; final plan revision 2, head `e76560ebd23d4c29e5d46eac528fd4fe795ad902`. |
| CI before merges | Bash, Pester and Rust tray checks passed on GitHub-hosted machines. PR21 final-head run: `39160631036`. This did not use the owner's custom runner pool. |
| Independent review | M4 had code/security review. The parity plan had Windows/security, Linux/cache and cleanup/orchestration reviews, correction rereviews and a later merge-policy review. This is planning sign-off, not runtime certification. |
| Branch cleanup | Both merged feature branches were removed locally and remotely. Only the base main worktree remained before creating this handover's short-lived documentation branch. |
| Parity implementation | All P00 through P28 remain `NOT_STARTED`; native VM providers, images, broker, allocator and certification tooling are proposed deliverables, not existing implementations. |

Pre-existing local changes were deliberately preserved: modified `.gitignore`,
untracked `.claude/` and `.planning/`, and existing base build outputs. Do not stage,
reset, stash, delete or reclassify these as your cleanup residue. The task-specific
temporary planning scope `.unlazy/parity-planning` was settled and removed; there
is no in-flight planning worker to resume from it. Use the committed ledger.

## Live machine: protected, separate from source main

The owner's last supplied live state was an ON pool of five runners, tray
`0.5.0 (42606d1)` installed under `C:\Program Files\aap-runner`, manager in the
`aap-runner` WSL distro, and supervisor under `C:\wsl\aap-runner-supervisor`.
Jobs were flowing. Repository merges did not deploy any of the new code. Treat
that reported runtime state as protected even if its version is now behind main.

**Do not stop, restart, repair, update, reinstall, drain experimentally or launch
anything against that live installation. Do not run `wsl -d aap-runner`, the tray,
its helper verbs, the supervisor task, or installer scripts against the host.**
Even Verify/Identity and apparently harmless scripts can execute WSL, mint tokens,
write files or restart components. Read their code instead of executing them here.

Other hard boundaries:

- At most **five total runner slots**, across legacy, Linux and Windows. Include
  idle/listening/warm slots and unreconciled cleanup. Never create a second pool
  of five alongside the first. VM overhead also consumes the aggregate budget.
- No Ubuntu 26.04. Use the pinned Ubuntu 24.04 profile and sources.
- Never read, copy, print or log `/etc/aap-runner/app.pem` or any real token.
  No secrets in chat, Git, status/inbox files, images, command lines or evidence.
  Synthetic secrets in disposable fixtures are the test mechanism.
- Never touch `C:\claude-obsidian\primus-cloud` or any alternate vault location.
  Do not read the vault from disk while following a generic skill or searching.
- Never delete Docker volumes. Preserve all live install/data/cache disks.
- Preserve `C:\temp\aap-cache-benchmark-2026-10-18` in full.
- No fork-PR workflows on shared self-hosted runners; no untrusted PR checkout with
  `pull_request_target`. Repository CI stays GitHub-hosted. Do not use the live pool
  to verify your changes.
- Keep egui, the existing elevated helper and PowerShell host supervisor. No new
  elevation path, tray named-pipe service, Rust service rewrite, autologon,
  owner-password storage, silent update or new Authenticode requirement.

Prior read-only host observations: Windows 11 Pro build 26300, 32 logical CPUs,
about 94 GiB RAM, Hyper-V tooling/virtualization available. The live pool was
configured for 26 CPUs and 72 GiB RAM with a roughly 197 GiB work disk. These are
dated observations, not proof of spare capacity or an approved test-VM budget.
Do not allocate the remainder from arithmetic alone while production jobs run.

## Target design and decisions to preserve

Use sealed, versioned golden images with disposable native VM workers for the first
two profiles: **Windows Server 2025 / Visual Studio 2026 x64** and **Ubuntu 24.04
x64**. The current minimal WSL/Sysbox image remains an explicitly named compatibility
backend during transition. Full Linux VM parity is not established by installing
more packages into that legacy image.

The host PowerShell coordinator owns one five-slot allocator and resource leases,
acquired before boot or registration. Lost heartbeat does not free a slot. Adopt
legacy reservations before admitting new workers. Profile counts are configurable
within one ceiling; no permanent Windows/Linux split was selected.

The existing WSL controller retains the App private key. New guests receive only
qualified short-lived registration material. Prefer JIT one-use configuration after
proving API behavior; an ordinary registration token is not inherently one-use.
P02 must prove and freeze host/guest management transport before providers fan out.
PowerShell Direct and isolated per-clone Linux SSH are candidates, not finished facts.
Guest admin/sudo is needed for hosted-equivalent setup; it must not expose host,
owner, controller or other-guest privileges and credentials.

Upstream candidate: `actions/runner-images` commit
`ee1ff4569e381a9649b400338bdc8ceb7e18a80e`. The plan links exact inventories,
templates and source. P01 must reconcile these with a real hosted job's image
identity before freezing baselines. Moving labels do not select historical images;
do not assume tomorrow's `windows-latest` still matches today's reference. Recheck
official primary sources when freezing versions, and record every inventory category.

Upstream Windows provisioning uses Azure builders. A local Hyper-V adapter, lawful
guest OS media/activation, provisioning reboots, default-user configuration, tests
and final sealing require real engineering. GitHub does not guarantee that a
historical image tag can still be rebuilt. Missing/drifting inputs are visible
blockers, not permission to omit tools and declare parity. The Linux 60 GiB default
is not a valid assumed Windows image budget. Account for base/build/clone/update/
rollback overlap and actual CPU/RAM/disk/IO enforcement.

The M4 wizard is already implemented in source. It uses existing GitHub/identity
pages, injected checks, helper.rs/win.rs and protected resumable install journals.
It installs the current Linux backend. Do not reimplement M4 or describe it as
having provisioned the new VM backends. M5 operator-distro removal and M6 lifecycle
features from the older roadmap are not silently complete or substitutes for parity.

## zccache: exact intended replacement

The owner explicitly selected **[zackees/zccache](https://github.com/zackees/zccache)**,
not another project with a similar name. Replace sccache completely in the final
runtime and consuming workflows, with qualified direct compilation for unsupported
cache modes. There is no sccache fallback.

Candidate Git tag: `1.15.6` without a `v` prefix. Commit:
`15ec9537af0d219e07b72ce2b3f97d5f68d72b5e`.

The owner tested its Linux x86_64 musl binary at
`C:\temp\aap-cache-benchmark-2026-10-18\bin\zccache`. Prior read-only metadata:
27,876,808 bytes, SHA-256
`f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc`.
This session hashed that file but did not execute it. The owner's benchmark is
not Windows qualification or independent proof of archive provenance.

P04 qualifies Linux and Windows artifacts/interfaces separately. The pinned feature
matrix marks native `cl.exe`/`link.exe` integration partial; CUDA caching is not
qualified by this plan. Do not enable a wrapper globally because the executable
exists. Compare uncached/cold/warm builds, errors, response files, debug outputs,
linking, concurrency, restart and poisoning behavior. A warm green build needs
observed cache hits to count as caching evidence. Full builds must also work direct.

Do not blindly rename sccache variables, reuse its on-disk format, or retain the
manager's raw oldest-file eviction for an indexed daemon cache. Qualify retention
APIs and account for metadata/log/temp bytes. Isolate trust roots; mutable sharing
and hardlink materialization require poisoning proof. Preserve the old deployed
generation until an approved cutover, even while new source removes sccache coupling.

## How to execute the ledger with parallel agents

Start P00, then P01, then P02. Their interfaces and cleanup gates unlock parallel
image acquisition, cache qualification, test-harness, broker and allocator work.
Do not start independent implementations that invent incompatible contracts first.
Use `ledger.json` as the dispatch source and `LEDGER.md` for each worker brief.

- One bounded worker task per branch/worktree with explicit file ownership, unique
  target/temp roots and resource manifest. Fresh worker context includes its brief,
  shared contracts, safety rules and acceptance oracles. Tell workers they are not
  alone and must not revert each other's work.
- Up to three workers plus coordinator, at most two compile-heavy jobs, one full
  suite and one image/IO-heavy job, subject to a stricter authorized lab budget.
  Never run two full suites simultaneously or borrow live runner capacity.
- Ledger lane names are Codex labels. In Claude Code, follow the owner's current
  Claude lane/model mapping for the same responsibility and difficulty. Do not
  invoke Codex-only APIs or invent unavailable models. Keep lead orchestration,
  implementation, independent verification and security review distinct.
- Coordinator-owned ledger/status updates and shared-schema/lockfile changes are
  serialized. Expand exact consumer-repository children before dispatch. Delegate
  disjoint parent/child ownership; children depend on complete external prerequisites,
  not their parent's COMPLETE state. Parent summary merge waits for child cleanup.
- `COMPLETE` means accepted, reviewed, merged and cleanup-verified. A commit, green
  test, PR or merge alone does not unlock a dependent item.
- At the first merge, close the global no-new-dispatch barrier. Clean its registered
  worktree(s), targets, temp/install staging, owned processes and disposable guest
  artifacts, verify absence independently, and persist a compact receipt before
  the next claim or merge. Existing independent work may finish its current item.
  Cleanup failure means HOLD, not starting another item.
- P00 itself needs a manual, independently verified bootstrap receipt before its
  own automation can gate subsequent tasks. Do not make its completion circular or
  accept its self-report as independent cleanup proof.

Read WORKTREES.md literally before destructive operations. Its tests include
squash/rebase merge proof, dirty and ignored unowned files, stale PIDs, locked files,
crash recovery, parent-child ordering and concurrent junction substitution. Static
path scans followed by ordinary recursive deletion are not race protection.
Never globally clean, prune, kill or delete shared caches to obtain a green receipt.
Named product images, rollback/cache assets and small durable evidence have separate
owners/retention; build targets and anonymous staging cannot be retained as evidence.

## Important sequencing corrections already found in review

Do not rediscover these by breaking production:

1. **P16 depends on P12**, and therefore on the shared allocator. Legacy reservations
   must not be implemented against a coordinator that has not landed.
2. **P23 prepares consumers without switching normal production routing.** It uses
   inert/manual reference and candidate fixtures. P27 activates each consumer only
   after approved profiles are available. P28 requires every activation child done.
3. **P17/P18 author and validate fixtures on the reference first.** Actual candidate
   guest execution belongs to P22/P24 after guest integration. Simulation is not
   native runtime proof.
4. Expected compiler errors/nonzero exits are successful negative evidence when
   they match their oracle. Do not repair away the intentional failures.
5. Parent PRs cannot merge before mandatory children finish, and deleting worktrees
   cannot follow junctions to another checkout or cache.

## Authorization and working style

The owner explicitly corrected an earlier instruction: **"I never merge myself"**
and **"you llms do it"**. Agents handle routine reviewed green PR merges, main
synchronization and branch/worktree cleanup. Do not leave the owner two green PRs
and ask them to merge. This is recorded in plan revision 2 and supersedes the older
owner-only merge wording in prior conversation/history.

Work on branches, open PRs with `gh`, merge only after independent review and
required checks, then fast-forward base main. Never commit task changes directly
on main or force-push. Author and committer for agent-created commits:
`special-place-administrator <197073597+special-place-administrator@users.noreply.github.com>`.
No `Co-Authored-By`, `Claude-Session` or other session trailers.

When the owner starts the next session to continue this handover, proceed with
ordinary repository work and record the execution direction under D0; do not spend
another session merely proposing the same plan. This handover-writing session did
not itself start P00. The distinct D2 lab/media/resource and D5 live-cutover gates
remain unsatisfied. Prepare concrete prerequisites and approval requests only when
those external actions become necessary; continue independent authorized code work.
Never infer permission to enable Hyper-V features, change networking, provision
test VMs, buy media/services, dispatch paid reference jobs or alter the live pool
from a plan mentioning them. Record missing proof honestly and leave its gate open.

Report milestones and material blockers, not every tool operation. Be candid about
mocked versus actual evidence. Use SymForge status at startup and its context/search/
references before raw source reads or edits; literal docs/config reads are appropriate.
Use Terminal Commander for long/noisy work, bounded waits and observed exit receipts.
No visible command windows. If tools fail, use the owner's documented fallback and
say what could not be verified, without relaxing secrets or live-host boundaries.

## Tests and proof expected

Existing source checks, in the isolated task environment:

```text
Rust, from crates/tray with a task-specific CARGO_TARGET_DIR:
  cargo fmt --all --check
  cargo clippy --all-targets --locked -- -D warnings
  cargo test --locked

Bash, on an authorized separate Linux environment:
  bash distro/manager.sh --self-check
  bash distro/bootstrap.sh --self-check
  bash tests/run.sh
  shellcheck 0.11 at -S warning on changed/relevant scripts

PowerShell, if supervisor/ or installer/ changes:
  Pester 5 suite on Windows PowerShell 5.1 AND pwsh 7
  installer/install-host.Tests.ps1 as required by the existing CI contract
```

The Rust toolchain is pinned to `1.99.0` in rust-toolchain.toml; read actual current
files rather than silently changing versions. Git Bash is insufficient for the
Linux suite because it lacks required setsid/flock behavior. Do not run that suite
by starting the active aap-runner distro. Do not install host-wide test dependencies
or start a fixture service that could interfere with production.

Change a versioned inter-component contract and its consumer tests/docs together.
Refresh `distro/staging.sha256` when manager.sh, bootstrap.sh,
manager.conf.example or another documented staged input changes. Use the repository's
actual staging manifest procedure; do not invent a partial hash update.

Prior M4 local results were reported as 134 Rust tests and 221 Pester tests on each
PowerShell version, plus fmt/clippy and green hosted CI. They are historical evidence,
not today's rerun or proof of live UAC/installation behavior. The M4 README explicitly
distinguishes headless/mocked tests from a disposable Windows VM first-install test.

Final parity acceptance requires every required inventory entry and actual job
environment, full native compile/link/test/package fixtures, setup/cache/artifact
actions, cold network acquisition, guest privilege boundaries, fresh-job reset,
cancellation/crash recovery, five-slot resource enforcement, cache correctness,
consumer workflows and update/rollback proof. Prove final sealed images after the
AAP/cache overlay, not only upstream recipes. A version probe, available Windows
archive, successful xwin link or all-green mocks cannot certify a profile.

## Exact next steps

1. Read the files above and recall project memory using the owner's normal MCPs.
   Treat this handover and current Git evidence as the way back into the project,
   not a request to repeat the whole architecture audit.
2. Check `git status --short`, `git branch -vv`, `git worktree list`, and fetch
   origin/main. Preserve the known dirty files. Fast-forward main only if safe;
   never reset or stash the owner's changes. Check for any newer work before dispatch.
3. Read all 29 ledger entries. Confirm their current states from real evidence.
   At this handover snapshot every one was NOT_STARTED. Do not mark anything complete
   because its documentation directory exists.
4. Establish the bounded team and P00's exact acceptance/ownership/worktree/temp
   manifest. A sibling disposable root such as the one specified in WORKTREES.md
   keeps build outputs out of base main. Implement P00 in its own branch/worktree.
5. Independently verify P00's negative controls and Git fixture integration, review
   cleanup security, open/merge its PR when checks pass, then independently prove
   its own cleanup. Only then dispatch P01, followed by P02.
6. P01 freezes real hosted profiles and actual consumer failures, including inputs
   that need external authorization. P02 freezes schemas/transports and proves the
   authorized lab assumptions before any provider fan-out. If D2 is missing, do
   useful independent work and report a precise blocked test instead of using live WSL.
7. Continue ready disjoint leaves in parallel within ledger and cleanup constraints.
   Keep the machine-readable ledger, evidence and handover current through reviewed
   changes. End each cycle with actual diff/check evidence and clean ownership state.

## First prompt for Claude Code

The owner can point the new session at this file with:

> Read HANDOVER-CLAUDE-PARITY.md fully and follow its linked reading order. Continue
> implementing the GitHub runner parity plan from the first incomplete ledger item,
> starting with P00 if still untouched. Use bounded agents in separate worktrees,
> independently verify and review, merge green PRs yourself, and clean each merged
> item's owned artifacts before the next dispatch. Preserve all live-runner, secret,
> vault, Docker-volume and unrelated-file restrictions. Do not deploy or provision
> a lab without the required specific authorization. Report milestones and evidence.

The intended result is working, measured native Windows and Ubuntu build parity
with the rig's protections and qualified zccache, not another planning-only pass.
