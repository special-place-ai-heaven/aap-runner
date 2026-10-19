# Cache qualification contract (version 2)

Owner: **P04** (writes the matrices). Readers: P13 (packaging), P14/P15 (guest wiring), P16
(legacy retirement of sccache), P20 (cache state in the tray), P22, P24. Schema:
[`cache-qualification.schema.json`](cache-qualification.schema.json), one document per platform
at `parity/cache/qualification/<platform>.json`. Fixtures: `fixtures/cache-qualification/`.
Pin and interface facts: [parity/baselines/zccache.md](../baselines/zccache.md).

Revision 2 (P02.2, 2026-10-20): a matrix holds at most 256 rows (was 64), Linux `debug-pdb` rows
cover every compiler version, and rule 6's trust namespace is the repository plus the ref trust
class. Matrix documents keep `schema` 1, and every revision-1 matrix stays valid.

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
   only for the image-default clang 18.1.3 and gcc 13.3.0; **P04.1** extends them to every
   compiler version. On Linux `debug-pdb` means DWARF `-g` output; there is no separate `-g`
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
6. Runtime: one cache root per trust namespace. A trust namespace is the repository **plus the
   trust class of the ref** that runs the job: pull-request and fork-branch jobs are one class,
   default-branch jobs another, so a repository alone is not a namespace. A root is shared only
   among jobs whose writers are at least as trusted as every reader; a pull-request job never
   writes a root that a default-branch job reads. The namespace comes from GitHub data, never from
   the guest. `ZCCACHE_MODE=COPY` or a proven reflink mode; hardlink delivery and cross-trust or
   cross-job mutable sharing stay off until P04/P13 prove poisoning and concurrency safety.
   Retention is the daemon's (budget via `ZCCACHE_CACHE_SIZE_BYTES` or `_PERCENT`); index, log,
   metadata and temp bytes are counted separately against the guest scratch budget. No
   manager-side oldest-file eviction. Requirements: [retention.md](../cache/qualification/retention.md).
7. A wrapper failure at runtime falls back to the direct compiler for that invocation and reports
   cache state `degraded` in `status.v5.json`; it never fails a build that would pass direct.

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
