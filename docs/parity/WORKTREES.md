# Worktree ownership and cleanup contract

This specifies automation to implement in P00. These are future operations, not
commands run against the live machine by this planning PR. The owner merges PRs.
The coordinator serializes claims, merge observations and cleanup under one ledger
lock. A worker may never declare itself COMPLETE.

## Claim and isolate

Before dispatch, require every dependency COMPLETE, the global cleanup barrier
open, an exclusive path lease, and the necessary build/test/resource token. Record
the reviewed origin/main SHA and create a unique branch and worktree from it.
Give workers the exact frozen interfaces, acceptance gates, protected paths and
ownership list. Tell each worker it is not alone and must accommodate other work.
No worker edits another owner's files, root manifests, lockfiles or shared schema.
Unexpected cross-owner changes go to the coordinator for a ledger revision first.

Expand a parent into required children before dispatching it. Children depend on
already-complete external prerequisites, never their own parent's COMPLETE state.
The coordinator atomically delegates disjoint ownership subsets; a parent does not
hold an overlapping write lease while a child works. The parent's summary PR becomes
merge-ready only after all required children are merged and cleanup-verified.
Do not merge a parent early and then need to claim children through its cleanup
barrier. If an unexpected early owner merge occurs, preserve the incomplete parent,
clean that merged attempt, and record a recovery/remainder item before reopening
dispatch; never manufacture COMPLETE to escape the barrier.

Suggested disposable layout (P00 must validate its actual configured root):

```text
C:\AI_STUFF\PROGRAMMING\aap-runner-work\parity\Pxx\attempt-N\
  repo\                 implementation worktree
  verify\               independently registered verification worktree, if needed
  target\               unique CARGO_TARGET_DIR
  verify-target\        independent verifier build outputs
  tmp\                  TEMP/TMP and tool-specific scratch
  downloads\            disposable installers and source archives
  images\               disposable build/clone disks; no live/product disks
  logs\                 temporary, sanitized diagnostics
```

The registry and compact evidence must live outside disposable roots. A manifest
records item/attempt, canonical root paths, branch and base SHA, registered worktree
IDs, target/temp environment, process/job handles with start times, lab VM/disk IDs,
resource leases, asset destinations, evidence references and owner. Register each
resource before creation. A crash between registration and creation is harmless;
an unregistered existing resource is a HOLD, not a cleanup guess.

Workers run cargo with their own target directory; verification has a different
target. Shared source-download/tool caches may be read under their documented
policy but are not owned cleanup assets. No builds in the base clone. No root
manifest/lockfile modification without an explicit serialized owner. Add newly
discovered files or child tasks to the ledger before touching them.

At most three workers, two compile-heavy jobs, one full suite and one image/IO-heavy
job run concurrently, subject to a stricter approved lab budget. Already busy live
runners are never implicitly borrowed as a test environment. Independent review
can overlap implementation of disjoint ready leaves; it cannot certify an old head.

## Review, merge and global barrier

Use these states, with evidence for every transition:

`NOT_STARTED → CLAIMED → IN_PROGRESS → VERIFIED → REVIEWED → PR_OPEN →
AWAITING_OWNER_MERGE → MERGED_CLEANUP_REQUIRED → CLEANUP_VERIFIED → COMPLETE`

Failure sets HOLD plus a reason and recovery owner. On a reviewed-head change,
invalidate affected checks/reviews; rerun before accepting. Security review is
independent for auth, helper verbs, elevation, credentials, guest transport,
image ingestion, cache trust and destructive cleanup. No self-approval.

The first observed merge closes a global no-new-dispatch barrier. No new item or
child can be claimed, and no dependent can start, until all merged tasks have
verified cleanup receipts. Already-running work may finish only its existing item.
Serialize cleanup with further merge processing; agents do not ask the owner to
merge another queued PR while cleanup is pending. If the owner merges several,
queue all of them for cleanup and keep the barrier closed until all are resolved.
Do not implement another ledger item in a merged worktree while waiting.

Commit or PR creation alone never permits deleting a worktree. Confirm via `gh`
that the correct repository/base PR is MERGED, its final reviewed head is the one
accepted, and its merge commit is reachable from freshly fetched origin/main.
Check the resulting scoped change against the reviewed result, accounting for
squash/rebase and intervening commits. Original-head ancestry alone fails for
squash merges; patch-ID alone is also insufficient proof. Record PR URL, accepted
head, merge SHA, origin/main SHA and the comparison result. An API outage,
unexpected head, conflicting result or uncertain merge identity means HOLD.

## Cleanup sequence

1. Retain the compact accepted test/review/merge evidence in the durable evidence
   store. Transfer only explicitly approved product images, rollback generations
   and runtime cache assets into their separately owned catalog. Record their
   owner, size, expiry and retention purpose. Do not retain build targets or whole
   SDK/installer trees by relabeling them as evidence.
2. Stop or await only manifest-owned Terminal Commander jobs/processes. Match both
   process identity and start time to prevent PID reuse. A live pool process or
   unrecognized child is never a kill target. Release disposable lab guests through
   the reviewed provider using exact VM IDs; absence must be positively observed.
3. Validate every deletion path with native PowerShell from end to end. Resolve
   absolute literal paths and verify containment in the one registered attempt
   root; reject drive roots, empty paths, parent traversal, UNC/device paths and
   alternate streams. Inspect the root, every ancestor and descendants for junctions,
   symlinks and other reparse points before recursion. A changed path identity or
   reparse point causes HOLD. Never follow one to delete elsewhere. Preflight scans
   alone are insufficient: P00 must implement and independently review race-resistant
   no-follow, handle-relative deletion or prove an equivalent protected, quiescent
   boundary that prevents concurrent path substitution for the entire operation.
   Revalidate identity at deletion; a same-process check/delete sequence by itself
   is not proof. If this guarantee is unavailable, HOLD rather than recurse.
4. Remove only registered, validated disposable targets/temp/download/build-image
   outputs through the qualified deletion routine. Native `Remove-Item -LiteralPath`
   is permitted only within the proved protected boundary; literal paths alone do
   not prevent a junction-swap race. Keep one PowerShell orchestration process.
   No PowerShell enumeration passed to cmd/batch deletion, string-built delete
   commands, broad globs, `git clean -fdx`, global process kills, Docker volume
   deletion or recursive sweep outside the attempt root.
5. Require both worktrees to have no unexpected tracked/untracked/ignored files.
   Inventory ignored files explicitly; ordinary `git status` misses them. Preserve
   ambiguous files and HOLD. Remove clean registered worktrees using normal
   `git worktree remove`, never `--force`. Verify their paths and exact Git
   worktree metadata entries are gone; do not use a global prune as a substitute.
   Remove validated now-empty attempt/container directories and temporary verifier
   outputs as well; stop at the registered boundary and preserve shared parents.
6. Delete only the merged local task branch. Normal non-force deletion is preferred.
   Squash/rebase may make Git's ancestry check refuse; P00 must provide a separately
   tested compare-and-swap ref deletion tied to the independently proved accepted
   head and merge receipt, or HOLD for manual resolution. Never use blanket `-D`,
   delete another branch, or automatically delete the remote branch.
7. Fetch and fast-forward base main only if pre-existing user changes are preserved.
   Compare against the initial dirty-state inventory; do not reset, stash or clean
   it to manufacture a clean result. A conflicting update is HOLD. Record base
   and origin SHAs and any preserved unrelated changes.
8. An independent verifier checks the registry, Git worktree list, literal filesystem
   paths, owned jobs/processes, lab VM/disks, leases and targets. A successful delete
   exit code alone is not an absence proof. Persist the cleanup receipt atomically;
   release path/resource leases and mark COMPLETE only after all checks pass.

For transient sharing violations use at most three retries over fifteen seconds;
then HOLD with exact owned resource IDs and sanitized diagnostics. Never broaden
the deletion boundary to make cleanup green. Resume idempotently from the last
persisted step after a crash. Cleanup failure keeps the global barrier closed.

Never delete the base clone's pre-existing target, shared Cargo/SDK caches,
`.gitignore` edits, `.claude/`, `.planning/`, the owner's cache benchmark directory,
either vault path, live install/controller/supervisor directories, or Docker
volumes. This list supplements positive manifest ownership; absence from this list
does not grant ownership.

## Receipt and automation acceptance

The durable receipt contains item/attempt, final reviewed head, PR/merge/base SHAs,
test and independent review identities, protected-state comparison, each disposed
resource ID/path and observed absence, retained assets with owner/retention,
process/job termination observations, released leases, verifier and timestamps.
Store no tokens, keys, credentialed URLs, registration material or raw environment
dumps. A receipt must be recoverable without keeping the worktree.

P00 implements deterministic tests with a temporary fixture repository and fake
resource providers, then a disposable local Git integration test. Required cases:

| Negative/control case | Required observation |
| --- | --- |
| Dependency incomplete; overlapping ownership; barrier closed | Claim refused before worktree creation |
| Parent proposed for merge before required children finish | Not merge-ready; children remain dispatchable from external prerequisites |
| Commit-only, open PR, wrong base/repository or changed reviewed head | Cleanup refused; worktree preserved |
| Merge commit, squash merge, rebase merge | Correct result accepted; original-head ancestry not required |
| Merged result differs; stale API or remote fetch fails | HOLD; no deletion |
| Junction/symlink at root, ancestor or nested child; path escape | HOLD; outside sentinel unchanged |
| Concurrent descendant/ancestor junction substitution during deletion | Outside sentinel untouched; safe refusal or qualified no-follow operation |
| Pre-existing dirty/untracked file or unknown process | Preserved; HOLD where ownership is ambiguous |
| Ignored but unowned file inside a worktree | Explicit inventory detects it; preserved and HOLD |
| PID reused; process start time differs | No kill issued |
| Locked target, partial deletion or guest teardown failure | Bounded retry; barrier remains closed |
| Crash before/after each persisted transition | Idempotent recovery; no double lease or premature COMPLETE |
| Two simultaneous claims or merges; owner merges several PRs | Atomic serialization; no next-item dispatch |
| Shared cache, benchmark directory, live-path and Docker-volume sentinels | No mutation or deletion |
| Clean success plus independent residue scan | Exact owned roots/resources absent; retained assets accounted |
| Empty attempt directories and verifier scratch remain | Cleanup incomplete until removed and absence proved |

The cleanup verifier itself runs outside the root it removes. Its temporary outputs
are also registered and cleaned; the durable compact receipt is its only leftover.
