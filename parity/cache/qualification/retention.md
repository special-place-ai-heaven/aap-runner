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
   At the pin all of this sits in `<root>/v1.15.6/`, beside a copy of the `zccache` binary
   (27,876,808 bytes on Linux) that zccache deploys there and runs as the root's daemon
   ([README](README.md), "Method"). P13 must:
   - measure non-artifact bytes per root (`du` of the root minus the artifact store) after the lab
     runs, and set a hard cap for them inside the guest scratch budget;
   - bound the journal and log files, by rotation if zccache offers it (**to confirm in lab**,
     the README documents none) or by the guest's own disposable lifetime;
   - report artifact, metadata, log and temp bytes separately in sanitized telemetry.
4. **One root per trust namespace.** [cache-qualification.md](../../contracts/cache-qualification.md)
   rule 6 defines the namespace and the job trust class (revision 3, amended by P13.2), and this
   requirement follows it. A trust namespace is the repository plus the trust class of the job, so
   a repository alone is not a namespace, and neither is a ref. The host takes the class from
   GitHub's record of the job assigned to the runner, never from the guest. A job is trusted only
   when its event is `push` or `schedule`, its `head_branch` is the default branch, its head
   repository is the repository itself, and its `head_sha` is the default branch's head when the
   host binds the class. Every other job is untrusted, including `workflow_dispatch`,
   `pull_request_target`, `workflow_run`, and tag pushes and re-runs at any commit other than
   the default branch's current head. An untrusted job gets only a private per-job root that goes
   with its VM. There is no shared untrusted root. A root may be shared only among jobs whose
   writers are at least as trusted as every reader, so an untrusted job never writes a root that
   a trusted job reads. The
   namespace key is the repository id, the trust class, the zccache version and the toolchain
   digest. Each root has its own daemon, endpoint, artifacts and indexes,
   because `ZCCACHE_CACHE_DIR` isolates all of them (R 422-437). `ZCCACHE_ENDPOINT` must not be
   set, since that would join two roots to one daemon. The qualification harness removes it,
   along with every other inherited `ZCCACHE_*` variable. `ZCCACHE_DAEMON_NAMESPACE` or
   `ZCCACHE_DAEMON_STATE_DIR` (R 464-489) may separate daemon identities. They never replace
   separate roots across trust boundaries.
5. **The poison step qualifies corruption handling only.** A passing poison step shows that a
   corrupted store entry is looked up and not served. It does not show that sharing a root is
   safe. A writer can store a well-formed but malicious entry that no integrity check rejects, and
   upstream does not claim to prove cache integrity (R 1123). Cross-trust sharing of a mutable
   root stays off whatever the poison results are, and cross-job sharing follows the
   writer-trust rule in requirement 4. `ZCCACHE_PATH_REMAP=auto` cross-worktree sharing
   (FM 64-67) stays off between trust namespaces. Inside one namespace it needs three runs
   first: a lab concurrency run, a poisoning run and a direct-equivalence run.
   `ZCCACHE_PATH_REMAP=auto` injects `-ffile-prefix-map` into C/C++ invocations and
   `--remap-path-prefix` into rustc invocations (FM 65-66). The compiler then no longer runs the
   command the build asked for. Debug info and diagnostics name the canonical path, not the
   worktree, so the equivalence run compares those outputs with a direct build of the same tree.
   The harness relocated check is one example.
6. **Copy delivery until hardlink delivery is proven.** Set `ZCCACHE_MODE=COPY` (R 548-557). Do not
   use `AUTO`, `LINK` or `REFLINK_OR_LINK_OR_COPY`. `AUTO` hardlinks C/C++ outputs, and the
   hardlink poisoning prevention (FM 50-51, 110) is an upstream claim, not P04 evidence. The
   harness has no hardlink mode: it always runs `COPY`. Its store overwrite does not test the
   real hardlink hazard, which is a build step writing into an output that shares its inode with
   the cache. Unlocking a hardlink mode therefore needs a separate lab step, recorded with an
   explicit matrix revision:
   1. Build warm in that mode until there is a hit.
   2. Write into the delivered output file in place, as a build tool appending to it would.
   3. Rebuild through the cache into a fresh output directory.
   4. Require artifacts equal to the uncached build.

   Reflink may be enabled per filesystem after the same proof.
7. **Daemon failure is not a build failure.** If the daemon is missing, crashes or rejects an
   invocation, the build runs the direct compiler for that invocation, and the cache state is
   `degraded` in `status.v5.json` (contract rule 7). `ZCCACHE_DISABLE=1` is the documented kill
   switch (R 562). Whether the wrapper itself falls through to the compiler on daemon loss is
   **to confirm in lab**, so P13 must not depend on that behaviour.
8. **Clearing a cache** means stopping that root's daemon and deleting that root. P13 owns this
   procedure inside the guest. `zccache clear` exists (R 411-412). Its effect on metadata, log and
   journal bytes is **to confirm in lab**. Docker volumes and the live legacy cache are never
   purged by P13 or P16 (ledger P16).
9. **No credentials in the daemon's environment.** The daemon inherits the environment of the
   process that starts it. Upstream writes crash dumps under the root's `crashes/` folder
   (R 433-434), and those dumps can hold process memory and environment. So P13 starts each root's
   daemon before Actions starts, from an environment with no runner token, JIT config, job token
   or key. A job step must never be the one that spawns it. Crash dumps and journals stay inside
   the disposable guest and are reported only as counts and sanitized telemetry. The
   qualification harness applies the same rule. It refuses to run when a variable name looks like
   a credential or a value carries URL credentials. On Linux it also starts every build and
   daemon under `env -i` with an allowlist, so the rule does not rest on names alone. P13 should
   start daemons the same way.
