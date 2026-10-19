# zccache 1.15.6 qualification (P04)

**State: static qualification and harness only. No row is qualified. Every row is `direct` with
the reason "unqualified - pending lab (P13/P22)".** This host runs the live production pool, and the
authorized lab (gate D2) does not exist yet. So nothing here ran zccache or a compiler under
zccache. The runtime matrix is a tracked follow-up that P13 and P22 run in the lab with the
harness below. Until a lab record lands, every compiler and invocation builds directly with no
wrapper. Full parity must hold that way (contract rule 3).

| File | Purpose |
|---|---|
| [linux-x86_64.json](linux-x86_64.json), [windows-x86_64.json](windows-x86_64.json) | The matrices, one per platform, in the [cache-qualification contract](../../contracts/cache-qualification.md) shape |
| [artifacts.md](artifacts.md) | Release assets, digests, member hashes and verification steps |
| [retention.md](retention.md) | Retention, byte accounting and isolation requirements for P13 and P16 |
| [harness/qualify.sh](harness/qualify.sh), [harness/qualify.ps1](harness/qualify.ps1) | The lab harnesses; [harness/fixtures](harness/fixtures) holds the C, C++ and Rust fixtures |

Tests: `tests/parity/cache/qualification/` (Pester for the Windows harness, Python for the
matrices, `harness_test.sh` for the Linux harness on real Linux only).

## Verdicts

The contract has two modes, `qualified` and `direct`. "Unqualified" and "direct-only" are not
separate enum values. Both are `direct`, and the `reason` text says which applies:

- `unqualified - pending lab (P13/P22); FEATURE-MATRIX L<n> ...`: a candidate with no lab
  record yet.
- `partial per upstream matrix - direct-only until proven; FEATURE-MATRIX L19 partial`: native
  MSVC `cl.exe` and `link.exe`. The pinned FEATURE-MATRIX line 19 marks them `partial`.
- `lab run failed: <checks>`: written by the harness when any check fails.
- `qualified` needs a committed harness record at `evidence_ref` with every check true, reviewed
  per row. The matrices already carry the planned `evidence_ref` path for each row. Those files
  do not exist yet, and the validator does not require them for `direct` rows. A test fails if a
  `qualified` row's file is missing.

A pair absent from a matrix is `direct`. That covers nvcc (FEATURE-MATRIX line 18 `no`), emcc,
MinGW `gcc 15.2.0` on the Windows image, and the clang bundled with Visual Studio, whose version
the P01 inventory does not record.

## Rows

Compiler versions come from the P01 inventories, and a test ties them to those files.

| Platform | Compiler | Versions | Invocations | Rows |
|---|---|---|---|---:|
| Linux | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces | 3 |
| Linux | clang, clang++ | 16.0.6, 17.0.6, 18.1.3 | compile-object, compile-pch, response-file, depfile, path-with-spaces | 30 |
| Linux | gcc, g++ | 12.4.0, 13.3.0, 14.2.0 | compile-object, compile-pch, response-file, depfile | 24 |
| Windows | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces, debug-pdb | 4 |
| Windows | clang, clang++ | 20.1.8 | as Linux clang | 10 |
| Windows | clang-cl | 20.1.8 | compile-object, response-file, debug-pdb, path-with-spaces | 4 |
| Windows | cl | VS 18.10.12224.181 | compile-object, compile-pch, response-file, debug-pdb | 4 |
| Windows | link, lld-link | VS 18.10.12224.181, 20.1.8 | link | 2 |

That makes 81 rows, all pending lab. The inventory gives the cl and link version only as the
Visual Studio and VC.Tools component versions. The harness records the `cl` banner, and the lab
replaces the version string with the exact `19.xx` toolset version in the first matrix revision
that qualifies anything.

## Method (per platform, compiler version and invocation)

Line citations refer to the upstream files at the pinned commit:
README <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/README.md>
and FEATURE-MATRIX <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/docs/FEATURE-MATRIX.md>
(fetched 2026-10-19; README SHA-256 `6d8450dc...46bb71`, equal to the copy inside both release archives).

Run in a disposable lab VM built from the P06 or P07 image, never on the owner's host or the live
distro. Use the archive verified per [artifacts.md](artifacts.md). The harness does steps 1-6 for
one pair per call. Steps 7-10 are lab procedures run around it.

1. **Uncached.** Build the fixture with the compiler directly, with no wrapper. Record the exit code
   and the SHA-256 of every file in the output directory.
2. **Cold.** Fresh `ZCCACHE_CACHE_DIR` and `ZCCACHE_MODE=COPY`. Build through zccache as
   `zccache <compiler> <args>` (README 359-366, 795-797). For rustc this is the form `RUSTC_WRAPPER`
   produces. Exit code and artifacts must equal the uncached build. The cold session must
   record zero hits.
3. **Warm.** Remove the outputs and build again. Exit code and artifacts must be equal. **A green
   warm build counts as caching evidence only with at least one observed hit.** Hits come from
   the per-session journal: `zccache session-start --journal <file>.jsonl` prints JSON with
   `session_id` (README 1254-1273), and journal lines with `outcome` `hit` or `link_hit` are
   counted (README 1240-1252). `zccache session-end <id> --json` output is kept for the record
   (README 1224-1229). Its field layout is not documented, so it is **to confirm in lab** and not
   used for the verdict. If `session-start` does not return a session id, hits are `null` and the
   row cannot qualify.
4. **Poisoned cache.** Overwrite every file under `<cache>/artifacts/` (README 433) and build
   again. The corrupted entry must not be served. The exit code and artifacts must still equal
   the uncached build. If the store holds no files there, the step records `null` and the row
   cannot qualify. The real store layout, including staged generations (README 501-530), is
   **to confirm in lab**.
5. **Deliberate errors stay errors.** Repeat uncached, cold and warm builds with the error fixture.
   Every exit code must be non-zero, and the primary artifact must not exist. A cached error must
   not turn into a success.
6. **Invocation classes.** `response-file` passes only `@file`. FEATURE-MATRIX line 21 claims
   nested `.rsp` expansion. `path-with-spaces` builds from `src with spaces` with absolute
   paths. `depfile` adds `-MD -MF`. `compile-pch` builds a precompiled header (`-x c-header` /
   `/Yc`). `debug-pdb` asks for debug output: `/Zi /Fd` for cl and clang-cl, `-C debuginfo=2`
   for rustc, which writes a sibling PDB. Link caching captures sibling `.pdb` files (FEATURE-MATRIX
   line 14). `link` links prebuilt objects; the error case is an unresolved symbol. MSVC and
   clang-cl use `/Brepro` for comparable bytes.
7. **Concurrency (`-j`).** Build a 32-object variant of the fixture with `make -jN` or
   `ninja -jN` through the wrapper. Use N of 1, 4 and the core count, cold then warm, on one root
   at a time. Compare artifacts with the uncached build and count journal hits. Run two
   concurrent cold builds of the same tree on one root and compare both against uncached.
   Required for any row before `ZCCACHE_PATH_REMAP` or shared roots are considered.
8. **Daemon restart.** Kill the daemon mid-build, then let the next invocation start it again
   (README 379-381, the daemon starts on demand). The interrupted build must either fail like a
   direct build would or finish with artifacts equal to uncached. The next warm build must still
   hit (README 1237-1238: artifacts survive restarts). The README documents no `stop` command or
   daemon process name, so the kill method is **to confirm in lab**.
9. **Unsupported invocations.** Run each compiler with an invocation the matrix does not list,
   for example `-E` (preprocess-only), an unknown flag or nvcc. The product never wraps such an
   invocation: P13 initializes wrappers only for qualified pairs, and everything else calls the
   compiler directly (contract rules 3 and 7). The lab still records what zccache does when handed
   one, whether it passes through, errors or caches. Any outcome other than direct-equivalent
   output keeps the pair `direct`. The README documents no pass-through rule, so this is **to
   confirm in lab**.
10. **Platforms.** Linux rows run on the P07 Ubuntu 24.04 image with the musl binary. Windows rows
    run on the P06 image in a Developer PowerShell (cl and link need `INCLUDE` and `LIB`). A Windows
    archive that exists, or a binary that starts, is not a pass (ledger P04).

### Equivalence

Byte-equal artifacts are the default oracle. Where a toolchain writes non-deterministic bytes, a row
can still qualify with a documented semantic comparison. Examples are PDB GUIDs and age, or
rustc metadata hashes when paths differ. The comparison names the tool, such as `llvm-pdbutil`
or `dumpbin /headers` with fields masked, and is reviewed with the record. The harness reports byte
inequality as a failed check. It never decides semantic equivalence.

## Running the harness (lab only)

```bash
export AAP_ZCCACHE_LAB=1   # only inside the disposable lab VM
parity/cache/qualification/harness/qualify.sh clang /usr/bin/clang-18 18.1.3 compile-object \
  /opt/zccache/zccache /tmp/rec.json \
  parity/cache/qualification/evidence/linux-x86_64/clang-18.1.3-compile-object.json /tmp/zq-work
```

```powershell
$env:AAP_ZCCACHE_LAB = '1'   # only inside the disposable lab VM
.\parity\cache\qualification\harness\qualify.ps1 -Compiler clang-cl -CompilerPath 'C:\Program Files\LLVM\bin\clang-cl.exe' `
  -CompilerVersion 20.1.8 -Invocation compile-object -Zccache C:\zq\zccache.exe -Out C:\zq\rec.json `
  -EvidenceRef parity/cache/qualification/evidence/windows-x86_64/clang-cl-20.1.8-compile-object.json -Work C:\zq\work
```

Exit codes: `0` record written (read `row.mode`), `2` usage, `3` refused, `4` the binary is not the
pinned release binary. Refusal comes first, before any argument is read. Both harnesses refuse
unless `AAP_ZCCACHE_LAB=1` is set. They also refuse when a live-install marker exists:
`/etc/aap-runner`, `/var/lib/ghrunner` or `/sys/fs/cgroup/aap.slice/aap-runner.slice` on Linux,
and on Windows `%ProgramData%\aap-runner`, `%ProgramFiles%\aap-runner` or `%SystemDrive%\wsl`.
The Linux harness also refuses under WSL. A record's `row` is copied into the matrix only after
review. The record itself is committed at its `evidence_ref`, the matrix's `matrix_revision`
is bumped, and `python -I parity/contracts/validate.py cache-qualification <matrix>` must pass.

## Deferred to P13 and P22

- Every runtime result: steps 1-10 for all 81 rows, plus the exact cl/link toolset version.
- Confirming the `session-end --json` layout, the artifact store layout used by the poison step,
  the daemon kill method, the pass-through behaviour for unsupported invocations, the
  journal and log growth, and whether a byte budget below the 40 GiB clamp is honoured.
- Running `tests/parity/cache/qualification/harness_test.sh` and shellcheck on real Linux.
- The hardlink and reflink modes, and any sharing across worktrees ([retention.md](retention.md)).
