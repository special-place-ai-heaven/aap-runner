# zccache retention and storage requirements (for P13 and P16)

Status: requirements, not measurements. Nothing here was run. Citations are the README at the pinned
commit (`R` = <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/README.md>,
line numbers) and the FEATURE-MATRIX at the same commit (`FM`). The contract is
[cache-qualification.md](../../contracts/cache-qualification.md) rule 6.

## What is replaced

The legacy distro currently bounds the compile cache in the manager. `distro/manager.sh` runs
`bound_sccache_tree` and `trim_sccache_tree` before each job and in post-job cleanup. These
measure the tree with `du -sb`. Over 15% of `AAP_WORK_DISK_GIB`, they delete the oldest files by
mtime until the tree is at or under 80% of that bound. That is raw oldest-file eviction. It
ignores entry boundaries, so jobs already running can miss a trimmed file (`distro/README.md`).
P16 removes it. No zccache root is ever trimmed by the manager or by any script outside the daemon.

## Requirements

1. **The daemon owns retention.** One daemon per cache root runs retention for its exact root
   (R 439-462). Defaults: 5% of filesystem capacity, clamped to 40-200 GiB, reduced to keep 30 GiB
   recovery free space. At 85% of budget it evicts entries older than four days in LRU order down to
   70%. At 100% or on low free space it evicts in LRU order regardless of age down to 80%. A
   daily pass expires entries older than 30 days while the daemon is alive.
2. **Set the budget explicitly.** P13 sets exactly one of `ZCCACHE_CACHE_SIZE_BYTES` or
   `ZCCACHE_CACHE_SIZE_PERCENT` (R 446-454) per root, derived from the guest scratch budget.
   It never relies on the filesystem-percentage default, because a guest disk is sized for builds,
   not for a 40 GiB floor. Whether a byte budget below the 40 GiB clamp is honoured exactly is
   **to confirm in lab**.
3. **Count everything else separately.** The budget covers allocated artifact files and pending
   writes only. Root-local indexes, logs and metadata are outside it (R 459-462). The root also
   holds `tmp/`, `depgraph/`, `index.bin`, `crashes/`, `logs/`, lock files and download-daemon state
   (R 433-436), plus `daemon-state/<namespace>` (R 482-489) and private staging below
   `{cache_root}/staging` (R 524-530). The compile journal grows with every compile (R 1240-1252).
   P13 must:
   - measure non-artifact bytes per root (`du` of the root minus the artifact store) after the lab
     runs, and set a hard cap for them inside the guest scratch budget;
   - bound the journal and log files, by rotation if zccache offers it (**to confirm in lab**,
     the README documents none) or by the guest's own disposable lifetime;
   - report artifact, metadata, log and temp bytes separately in sanitized telemetry.
4. **One root per trust namespace.** Default is one root per repository. Each root has its own
   daemon, endpoint, artifacts and indexes, because `ZCCACHE_CACHE_DIR` isolates all of them
   (R 422-437). `ZCCACHE_ENDPOINT` must not be set, since that would join two roots to one daemon.
   The qualification harness removes it, with every other inherited `ZCCACHE_*` variable.
   `ZCCACHE_DAEMON_NAMESPACE` or `ZCCACHE_DAEMON_STATE_DIR` (R 464-489) may separate daemon
   identities. They never replace separate roots across trust boundaries.
5. **No cross-trust or cross-job mutable sharing.** `ZCCACHE_PATH_REMAP=auto` cross-worktree
   sharing (FM 64-67) stays off between trust namespaces. Inside one namespace it needs three
   things first: a lab concurrency run, a poisoning run, and a direct-equivalence run.
   `ZCCACHE_PATH_REMAP=auto` injects `-ffile-prefix-map` into C/C++ invocations and
   `--remap-path-prefix` into rustc invocations (FM 65-66). The compiler then no longer runs
   the command the build asked for. Debug info and diagnostics name the canonical path, not
   the worktree, so the equivalence run compares those outputs with a direct build of the same
   tree. The harness relocated check is one example.
6. **Copy delivery until poisoning is proven.** Set `ZCCACHE_MODE=COPY` (R 548-557). Do not use
   `AUTO`, `LINK` or `REFLINK_OR_LINK_OR_COPY`. `AUTO` hardlinks C/C++ outputs, and the
   hardlink poisoning prevention (FM 50-51, 110) is an upstream claim, not P04 evidence.
   Hardlink materialisation needs its own lab record, using the harness poison step with a
   hardlink mode, and an explicit matrix revision. Reflink may be enabled per filesystem after the
   same proof.
7. **Daemon failure is not a build failure.** If the daemon is missing, crashes or rejects an
   invocation, the build runs the direct compiler for that invocation, and the cache state is
   `degraded` in `status.v5.json` (contract rule 7). `ZCCACHE_DISABLE=1` is the documented kill
   switch (R 562). Whether the wrapper itself falls through to the compiler on daemon loss is
   **to confirm in lab**, so P13 must not depend on that behaviour.
8. **Clearing a cache** means stopping that root's daemon and deleting that root. P13 owns this
   procedure inside the guest. `zccache clear` exists (R 411-412). Its effect on metadata, log and
   journal bytes is **to confirm in lab**. Docker volumes and the live legacy cache are never
   purged by P13 or P16 (ledger P16).
