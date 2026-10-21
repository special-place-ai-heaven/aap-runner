# Cache qualification contract (version 2)

Owner: **P04** (writes the matrices). Readers: P13 (packaging), P14/P15 (guest wiring), P16
(legacy retirement of sccache), P20 (cache state in the tray), P22, P24. Schema:
[`cache-qualification.schema.json`](cache-qualification.schema.json), one document per platform
at `parity/cache/qualification/<platform>.json`. Fixtures: `fixtures/cache-qualification/`.
Pin and interface facts: [parity/baselines/zccache.md](../baselines/zccache.md).

Revision 2 (P02.2, 2026-10-20): a matrix holds at most 256 rows (was 64), Linux `debug-pdb` rows
cover every compiler version, and rule 6's trust namespace is the repository plus the job's trust
class (event, ref and head repository). Matrix documents keep `schema` 1, and every revision-1
matrix stays valid.

Rule 6 amendment (P13 security review, 2026-10-20): `workflow_dispatch` is untrusted, a tag push is
trusted only when its `head_sha` is reachable from the default branch (that test is superseded by
P13.2), the class is derived by the host from GitHub's job record matched by `runner_id` and
`runner_group_id`, untrusted jobs get only a private per-job root, and the namespace key adds the
zccache version. No schema change.

Rule 6 amendment (P13.2, 2026-10-21): GitHub's run record does not say whether `head_branch` names a
branch or a tag, so reachability from the default branch is not enough: a job is trusted only when
its `head_sha` is the default branch's head when the host binds the class (the branch-only ref
endpoint names that branch of that repository at that commit), and only in a repository the owner
enabled. Runs superseded before binding and re-runs of older runs get a private root. No schema
change.

## Rules (DECIDED)

1. zccache **1.15.6**, tag `1.15.6`, commit `15ec9537af0d219e07b72ce2b3f97d5f68d72b5e`, release
   archives `zccache-v1.15.6-x86_64-unknown-linux-musl.tar.gz`
   (`885a109c...28e59f7`) and `zccache-v1.15.6-x86_64-pc-windows-msvc.zip`
   (`a9e2b079...fd949b`). The schema pins version, commit, archive name and hash per platform.
   `binary_sha256` is filled by P04 after unpacking; the owner's benchmark binary is compared,
   never moved or modified.
2. **No sccache**: no sccache binary, renamed wrapper, variable, cache format, path or fallback in
   any mode. `validate.py` rejects a matrix that mentions it.
3. Rows are unique per (compiler, compiler_version, invocation); `evidence_ref` stays under
   `parity/cache/qualification/` with no `..`. Every compiler and invocation pair is `qualified` (with `evidence_ref` under
   `parity/cache/qualification/`) or `direct`. A pair missing from the matrix is `direct`.
   `direct` means the native compiler with no wrapper; full parity must hold with every pair direct.
   A matrix has at most 256 rows. Revision 1 allowed 64, so P04 shipped Linux `debug-pdb` rows
   only for the image-default clang 18.1.3 and gcc 13.3.0; P04.1 extended them to every
   compiler version (Linux matrix revision 2). On Linux `debug-pdb` means DWARF `-g` output; there is no separate `-g`
   invocation.
4. `qualified` needs, per platform and compiler version: uncached, cold and warm builds with equal
   exit codes and equivalent outputs (reproducible fixture or documented semantic comparison);
   deliberate compile errors stay errors; a warm build shows a real hit in sanitized telemetry;
   response files, paths with spaces, PDB/debug output, depfiles and unknown flags exercised;
   daemon kill and restart mid-build still produce correct results.
5. Starting state at the pin: `cl` and `link` are `direct` (feature matrix: native integration
   "partial"); `nvcc` is `direct` (unsupported); `rustc` through `RUSTC_WRAPPER`, Clang and
   clang-cl are candidates for P04; GCC as a wrapper target is not listed in the README tool list,
   so it needs its own evidence.
6. Runtime: one cache root per trust namespace. A trust namespace is the repository plus the trust
   class of the job, so a repository alone is not a namespace. A job is **trusted** only when all
   hold: its event is `push` or `schedule`; its `head_branch` is the repository's default branch;
   its head repository is the repository itself; and its `head_sha` is the default branch's head
   when the host binds the class. Every other job is **untrusted**: `workflow_dispatch` (any
   untrusted job in the same repository whose `GITHUB_TOKEN` has `actions: write` can dispatch a run
   on the default branch with inputs the attacker chooses, so the event and ref do not make it
   trusted), `pull_request`, `pull_request_target`, `workflow_run`, `issue_comment`, `merge_group`,
   pushes to any other branch (`dependabot/*`, `renovate/*`, feature branches), tag pushes and
   re-runs at any commit other than the default branch's current head, and any event this rule does
   not name. GitHub's run record has no ref field, and for a tag push `head_branch` is the tag's
   name, so a tag named like the default branch gives a record that looks exactly like a push to
   that branch. The rule therefore does not depend on telling them apart: the job is trusted only
   when, at the time the host binds the class, its `head_sha` IS the default branch's head: the
   branch-only, exact-match endpoint `GET /repos/{o}/{r}/git/ref/heads/{default_branch}` answers
   `ref` exactly `refs/heads/<default_branch>`, `object.type` `commit`, the `url` of that ref in that
   repository and `object.sha` equal to that `head_sha`. Another sha is untrusted; a failed call or
   an answer about another ref, object or repository means no class and no shared root. A
   repository gets a shared root only once the owner's decision to enable it is recorded host-side;
   the host computes no class for any other repository. A tag or a re-run at any older commit,
   including an intermediate commit of a merged pull request that was never reviewed on its own, is
   untrusted, live or deleted. What remains is a run of the current head started at a time a writer
   chose (a tag at the current head, a re-run while its commit is still the head): it runs exactly
   the reviewed head, as a push to the branch would. The cost: a run whose push was superseded
   before binding, and a re-run of an older run, get a private root (a lower hit rate, accepted). A
   tag ruleset that stops writers from creating a tag with the default branch's name is not a
   condition of the class but is RECOMMENDED for every enabled repository, because of what remains
   without it: while a tag named like the default branch exists, the bare name (`main`) is
   ambiguous in a job's scripts (git prefers `refs/tags/main` to `refs/heads/main`), and a
   tag-triggered run of the current head runs the reviewed head's workflow files with tag values in
   `github.ref`, `github.ref_type` and `github.ref_name`; steps that branch on those values are
   reviewed code of that head.
   The ref alone never decides the class: `pull_request_target`, `workflow_run`
   and `issue_comment` run on the default branch with input an outsider controls. A root is shared
   only among jobs whose writers are at least as trusted as every reader; an untrusted job never
   writes a root that a trusted job reads. The class comes from GitHub's record of the job GitHub
   assigned to the runner (event, ref and head repository), never from anything the guest reports,
   and is bound before any shared root is attached to the guest. When that record is not available
   in time, the job gets no shared root (direct compilation, or a per-job root destroyed with the
   VM). Until the owner decision below is applied, the broker's App has only the self-hosted runners
   permission (broker.md), which cannot read a job's event or ref. This rule replaces the ref-based
   trust class in retention.md requirement 4; P04.1 aligned that file with this rule.
   The class source (P13, revision 3 of this rule; security review of P13). The host derives the
   class from GitHub's record of the job assigned to the runner, matched by `runner_id` (from the
   broker ledger) and `runner_group_id`, and exactly one match is required: zero or several matches
   mean no shared root. The broker mints a per-lookup installation token narrowed to the one
   repository with `actions`, `contents` and `metadata` read only, and the App is installed on
   selected repositories only (the runner group's repositories). This adds `actions: read` and
   `contents: read` to the App and is an OWNER decision, recorded here as such.
   An untrusted job gets only its private per-job root: there is no shared untrusted root, because
   an untrusted job must never share a root with another job that could hold secrets or a write
   token. The namespace key is the repository id, the trust class, the zccache version and the
   toolchain digest (the zccache version is part of the key so a re-pin starts a new root). The
   host never mounts a namespace disk after a guest has had it: it creates the disk once to write
   the marker, a reset is delete and recreate, and the size is measured as the VHDX file length on
   the host.
   `ZCCACHE_MODE=COPY` or a proven reflink mode; hardlink delivery and cross-trust or
   cross-job mutable sharing stay off until P04/P13 prove poisoning and concurrency safety.
   Retention is the daemon's (budget via `ZCCACHE_CACHE_SIZE_BYTES` or `_PERCENT`); index, log,
   metadata and temp bytes are counted separately against the guest scratch budget. No
   manager-side oldest-file eviction. Requirements: [retention.md](../cache/qualification/retention.md)
   (retention.md requirement 4 follows rule 6).
7. A wrapper failure at runtime falls back to the direct compiler for that invocation and reports
   cache state `degraded` in `status.v5.json`; it never fails a build that would pass direct. A zero
   exit whose declared outputs (the object, the depfile) are missing, empty or not regular files is
   a wrapper failure (P13.3); a call whose outputs the shim cannot name (including calls that write
   sidecars it does not check, and Windows device outputs) builds directly; rustc, link and
   clang-cl `/Fd` outputs rely on zccache's own delivery and P04's evidence. Accepted residuals
   (guests/cache/README.md): concurrent writers of one output path inside one VM, hard-linked outputs
   on Windows (COPY mode is the control), and the daemon copy zccache deploys into a root, which is
   not hash-checked until P22.

## Matrix template (both platforms)

| Compiler | Invocations to qualify | Start mode |
|---|---|---|
| rustc | rustc-wrapper, link, path-with-spaces, debug-pdb (Windows) | candidate |
| clang / clang++ | compile-object, compile-pch, response-file, depfile, path-with-spaces; on Linux also debug-pdb (`-g`) for every version | candidate |
| gcc / g++ (Linux) | compile-object, compile-pch, response-file, depfile, debug-pdb (`-g`) for every version | candidate, evidence required |
| clang-cl (Windows) | compile-object, response-file, debug-pdb, path-with-spaces | candidate |
| cl (Windows) | compile-object, compile-pch, response-file, debug-pdb | direct |
| link / lld-link (Windows) | link | direct |
| nvcc | any | direct, unsupported |

## Negative fixtures

`qualified` without evidence, a duplicate row, a reason that falls back to sccache, release 1.15.5, a Linux
matrix that names the Windows archive, and a matrix of 257 rows. Valid: both P04-shaped matrices
and a 69-row Linux matrix with `debug-pdb` rows for every compiler version.
