# zccache 1.15.6 qualification (P04)

**State: static qualification and harness only. No row is qualified. Every row is `direct`.**
This host runs the live production pool, and the authorized lab (gate D2) does not exist yet. So
nothing here ran zccache or a compiler under zccache. The runtime matrix is a tracked follow-up
that P13 and P22 run in the lab with the harness below. Until a row qualifies, its compiler and
invocation build directly with no wrapper. Full parity must hold that way (contract rule 3).

| File | Purpose |
|---|---|
| [linux-x86_64.json](linux-x86_64.json), [windows-x86_64.json](windows-x86_64.json) | The matrices, one per platform, in the [cache-qualification contract](../../contracts/cache-qualification.md) shape |
| [artifacts.md](artifacts.md) | Release assets, digests, member hashes and verification steps |
| [retention.md](retention.md) | Retention, byte accounting and isolation requirements for P13 and P16 |
| [harness/qualify.sh](harness/qualify.sh), [harness/qualify.ps1](harness/qualify.ps1) | The lab harnesses for Linux and Windows |
| [harness/record.jq](harness/record.jq), [harness/journal.jq](harness/journal.jq) | The verdict and the journal counter, shared by both harnesses |
| [harness/fixtures](harness/fixtures) | The C, C++ and Rust fixtures, each with a deliberate-error twin |

Tests live in `tests/parity/cache/qualification/`. Pester covers the Windows harness and
`record.jq`, and Python covers the matrices. `harness_test.sh` covers the Linux harness and needs
real Linux with bash, coreutils and jq. Hosted `ubuntu-latest` is enough, and the test needs no
zccache.

## Verdicts

The contract has two modes, `qualified` and `direct`. "Unqualified" and "direct-only" are not
separate enum values. All of them are `direct`, and the `reason` text says which applies:

- `unqualified - pending lab (P13/P22); FEATURE-MATRIX L<n> ...` marks a candidate without lab
  results.
- `partial per upstream matrix - direct-only until proven; FEATURE-MATRIX L19 partial` covers native
  MSVC `cl.exe` and `link.exe`. The pinned FEATURE-MATRIX line 19 marks them `partial`.
- `direct per upstream binary-crate pass-through (README 400-403)` covers the rustc `link` and
  `debug-pdb` rows. Upstream passes binary and proc-macro crates through without caching, so these
  rows can never show a warm hit. The harness still runs them to show direct-equivalent output.

The harness never writes `qualified`. Its record carries `harness_pass` and a row that stays
`direct`, with the reason `harness checks pass; lab steps 7-9 pending` or
`harness checks failed: <checks>`. A reviewer changes a matrix row to `qualified` only when all of
these hold:

1. The record committed at the row's `evidence_ref` has `harness_pass` true, so every check from
   method steps 1-6 is true.
2. Lab steps 7 (concurrency), 8 (daemon restart) and 9 (unsupported invocations) passed for that
   pair. Each is recorded as `true` in the record's `lab_gates`, with its logs committed beside
   the record. The harness leaves the three gates `null`.
3. The record's row matches the matrix row on compiler, version, invocation and `evidence_ref`.
   The record's zccache hash equals the matrix `binary_sha256`.

Only the matrix row changes mode. The record's own row stays `direct`. `test_matrix.py` enforces
all three conditions for every `qualified` row. The matrices already carry a unique planned
`evidence_ref` per row. Those files do not exist yet.

A pair absent from a matrix is `direct`. That covers nvcc (FEATURE-MATRIX line 18 `no`), emcc,
MinGW `gcc 15.2.0` on the Windows image, the clang bundled with Visual Studio (the P01 inventory
does not record its version) and `-g` builds with non-default Linux compilers (see "Rows").

## Rows

Compiler versions come from the P01 inventories, and a test ties them to those files.

| Platform | Compiler | Versions | Invocations | Rows |
|---|---|---|---|---:|
| Linux | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces | 3 |
| Linux | clang, clang++ | 16.0.6, 17.0.6, 18.1.3 | compile-object, compile-pch, response-file, depfile, path-with-spaces | 30 |
| Linux | clang, clang++ | 18.1.3 | debug-pdb (`-g`) | 2 |
| Linux | gcc, g++ | 12.4.0, 13.3.0, 14.2.0 | compile-object, compile-pch, response-file, depfile | 24 |
| Linux | gcc, g++ | 13.3.0 | debug-pdb (`-g`) | 2 |
| Windows | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces, debug-pdb | 4 |
| Windows | clang, clang++ | 20.1.8 | as Linux clang without debug-pdb | 10 |
| Windows | clang-cl | 20.1.8 | compile-object, response-file, debug-pdb, path-with-spaces | 4 |
| Windows | cl | VS 18.10.12224.181 | compile-object, compile-pch, response-file, debug-pdb | 4 |
| Windows | link, lld-link | VS 18.10.12224.181, 20.1.8 | link | 2 |

| Reason class | Rows |
|---|---:|
| Unqualified, pending lab | 77 |
| Direct per upstream binary-crate pass-through (rustc link, debug-pdb) | 3 |
| Direct-only, MSVC partial (cl, link) | 5 |
| Total (Linux 61, Windows 24) | 85 |

The contract has no separate `-g` class, so on Linux `debug-pdb` stands for DWARF `-g` output.
Those rows target the classic `DW_AT_comp_dir` cache hazard. The schema caps a matrix at 64 rows,
so `-g` rows exist only for the image defaults. Clang 18 is the default per the P01 baseline
(B3 `clang.default_version`). GCC 13 is the default because the image's `gcc` package
`4:13.2.0-7ubuntu1` selects gcc-13. Other versions build `-g` directly until a contract revision
(P02) raises `maxItems`.

The inventory gives the cl and link version only as the Visual Studio and VC.Tools component
versions. The harness records the `cl` banner. The lab replaces the version string with the exact
`19.xx` toolset version in the first matrix revision that qualifies anything.

## Method (per platform, compiler version and invocation)

Line citations refer to the upstream files at the pinned commit, fetched 2026-10-19:

| File | URL | SHA-256 |
|---|---|---|
| README | <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/README.md> | `6d8450dc07e621383da62a9aef854d7c1bc9d1e66d55415c77dddd786746bb71` (equal to the copy in both archives) |
| FEATURE-MATRIX | <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/docs/FEATURE-MATRIX.md> | `4f80dce50c9e15fb250e9534c7f388c87e6aff57d7a647d17be71b98206391cf` |

Run in a disposable lab VM built from the P06 or P07 image, never on the owner's host or the live
distro. Use the archive verified per [artifacts.md](artifacts.md). One harness call covers steps
1-6 for one pair. Steps 7-9 are lab procedures and qualification gates for every row.

Before any build, the harness does the following:

- It verifies `zccache` and its sibling `zccache-fp` against the pinned hashes, and exits 4 on a
  mismatch.
- It removes every `ZCCACHE_*` variable inherited from the lab shell, including `ZCCACHE_ENDPOINT`,
  `ZCCACHE_PATH_REMAP` and `ZCCACHE_SESSION_ID`, and records the removed names. It sets only
  `ZCCACHE_MODE=COPY`, plus `ZCCACHE_CACHE_DIR` and `ZCCACHE_SESSION_ID` for each wrapped run.
- For non-MSVC compilers, it checks that the `--version` banner names the matrix version, and
  exits 2 otherwise. It records the compiler's path and SHA-256.
- It gives every case its own fresh cache root: `cache-ok` for cold, warm and relocated builds,
  `cache-error`, `cache-poison-same-size` and `cache-poison-marker`. It never deletes a cache root,
  because that root's daemon may still be running. The README documents no stop command, so
  daemons stay up until the disposable VM goes.
- It runs every build with the working directory at the fixture tree.

1. **Uncached.** Build the fixture with the compiler directly, with no wrapper. Record the exit code
   and the SHA-256 of every file in the output directory.
2. **Cold.** Build through zccache as `zccache <compiler> <args>` (README 359-366, 795-797) on a
   fresh root with `ZCCACHE_MODE=COPY`. For rustc this is the form `RUSTC_WRAPPER` produces. Exit
   code and artifacts must equal the uncached build. The cold session must record zero hits.
3. **Warm.** Remove the outputs and build again on the same root. Exit code and artifacts must be
   equal. **A green warm build counts as caching evidence only with at least one observed hit.**
   Hits come from the per-session journal. `zccache session-start --journal <file>.jsonl` prints
   JSON with `session_id` (README 1254-1273). Journal lines with `outcome` `hit` or `link_hit`
   count as hits (README 1240-1252). The harness keeps `zccache session-end <id> --json` output
   (README 1224-1229), but its layout is undocumented, so it is **to confirm in lab** and not used
   for the verdict. Without a session id, the journal is `null` and the row cannot pass.
4. **Poisoned cache, two variants.** Each variant gets its own root. The harness primes the root
   with one build through zccache and corrupts every file under `<root>/artifacts/` (README 433).
   Then it builds again in a journaled session.
   - `same_size` adds one to every byte and keeps each file's size and modification time, so only
     a content check can notice.
   - `marker` replaces each file with `P04-POISON`.

   A variant passes when it meets all of these conditions:
   - at least one file was corrupted;
   - the priming build's exit equals the uncached build's exit;
   - the build's exit code and artifacts equal the uncached build;
   - the journal shows the invocation was looked up, with at least one entry and no hit.

   The journal outcome for a rejected entry (`miss` or `error`) is **to confirm in lab**. The check
   accepts either but never a hit. The store layout, including staged generations
   (README 501-530), is also **to confirm in lab**.
5. **Deliberate errors stay errors.** Build the error fixture uncached, cold and warm on its own
   root. The uncached exit must be non-zero. The cold and warm exits must equal it, so a wrapper
   or daemon failure that exits with another code fails. No primary artifact may exist.
6. **Invocation classes.**
   - `response-file` passes only `@file`. FEATURE-MATRIX line 21 claims nested `.rsp` expansion.
   - `path-with-spaces` builds from `src with spaces` with absolute paths. For rustc it builds the
     `lib.rs` library, the cacheable crate type.
   - `depfile` adds `-MD -MF`.
   - `compile-pch` builds a precompiled header (`-x c-header` / `/Yc`).
   - `link` links prebuilt objects. The error case is an unresolved symbol. Link caching captures
     sibling `.pdb` files (FEATURE-MATRIX line 14).
   - `debug-pdb` asks for debug output: `-g -c` on Linux, `/Zi /Fd` for cl and clang-cl, and
     `-C debuginfo=2` for rustc. The clang-cl row is marked **to confirm in lab**, because `/Zi`
     with `/c` may embed CodeView in the `.obj` and ignore `/Fd`, writing no PDB.
   - debug-pdb uses relative paths. After the warm build, the harness copies the fixtures to a
     second tree. There it builds directly, then through zccache with the warm `cache-ok` root and
     the same arguments. The two outputs must be equal. A cache that ignored the working directory
     would serve the first tree's `DW_AT_comp_dir` or PDB path.
   - MSVC and clang-cl use `/Brepro` for comparable bytes.
7. **Concurrency, a gate for every row.** Every real build runs in parallel (cargo, `make -j`,
   ninja), so no row qualifies without this step. Build a 32-object variant of the fixture with
   `make -jN` or `ninja -jN` through the wrapper. Use N of 1, 4 and the core count, cold then warm,
   on one root at a time. Compare the artifacts with the uncached build and count journal hits.
   Then run two concurrent cold builds of the same tree on one root and compare both against
   uncached. `ZCCACHE_PATH_REMAP` and shared roots need this result too, plus the extra proof in
   [retention.md](retention.md).
8. **Daemon restart, a gate for every row.** Kill the daemon mid-build, then let the next
   invocation start it again (README 379-381: the daemon starts on demand). The interrupted build
   must either fail like a direct build would or finish with artifacts equal to uncached. The next
   warm build must still hit (README 1237-1238: artifacts survive restarts). The README documents no
   `stop` command or daemon process name, so the kill method is **to confirm in lab**.
9. **Unsupported invocations, a gate for every row.** Run each compiler with an invocation the
   matrix does not list, for example `-E` (preprocess-only), an unknown flag, or nvcc. The product
   never wraps such an invocation. P13 initializes wrappers only for qualified pairs, and
   everything else calls the compiler directly (contract rules 3 and 7). The lab still records
   what zccache does with one: pass through, error or cache. Any outcome other than
   direct-equivalent output keeps the pair `direct`. Upstream documents one pass-through rule:
   proc-macro and binary rustc crates are not cached (README 400-403). That is why the rustc `link`
   and `debug-pdb` rows are direct. For every other invocation the behaviour is **to confirm in
   lab**.
10. **Platforms.** Linux rows run on the P07 Ubuntu 24.04 image with the musl binary. Windows rows
    run on the P06 image in a Developer PowerShell (cl and link need `INCLUDE` and `LIB`). A Windows
    archive that exists, or a binary that starts, is not a pass (ledger P04).

### Equivalence

Byte-equal artifacts are the default oracle. Where a toolchain writes non-deterministic bytes, a row
can still qualify with a documented semantic comparison. Examples are PDB GUIDs and age, or
rustc metadata hashes when paths differ. The comparison names the tool, such as `llvm-pdbutil`
or `dumpbin /headers` with fields masked, and is reviewed with the record. The harness reports byte
inequality as a failed check. It never decides semantic equivalence.

## Evidence record

The harness writes one JSON record per call. The verdict comes from `record.jq`, and the fields are:

- `command`: the harness invocation, without machine paths.
- `tool_versions`: the compiler's banner, path and SHA-256, zccache's version and SHA-256, the
  `zccache-fp` SHA-256, and the prerequisite compiler for link rows. Values are printable ASCII of
  at most 120 characters, as the evidence bundle requires.
- `env`: the variables the harness set and the `ZCCACHE_*` names it removed.
- `runs` and `error_runs`: each with exit code, artifact hashes, argv, cache root name and
  journal counts.
- `checks`, `harness_pass` and `lab_gates`.
- `row`: always `direct`.

The record holds no log body and no environment value from the lab shell. P13 and P22 wrap each
record in an evidence bundle per [evidence-cleanup.md](../../contracts/evidence-cleanup.md). They
add `head_sha`, `contract_revision` (`cache-qualification@1`), `os_version`, `verifier` and the
remaining bundle fields, and copy `command` and `tool_versions` from the record.

## Running the harness (lab only)

The harness needs jq 1.7 or later, which both baseline images ship, and `zccache-fp` beside
`zccache`.

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

| Exit | Meaning |
|---:|---|
| 0 | Record written; read `harness_pass` |
| 1 | Unexpected harness error; no record |
| 2 | Usage: bad arguments, a banner that does not name the version, or no jq |
| 3 | Refused: not a lab |
| 4 | `zccache` or `zccache-fp` is not the pinned release binary |

Refusal comes first, before any argument is read. Both harnesses refuse unless
`AAP_ZCCACHE_LAB=1` is set. They also refuse when a live-install marker exists:

- Linux: `/etc/aap-runner`, `/var/lib/ghrunner` or `/sys/fs/cgroup/aap.slice/aap-runner.slice`.
- Windows: `%ProgramData%\aap-runner`, `%ProgramFiles%\aap-runner` or `%SystemDrive%\wsl`.

The Linux harness also refuses on signs of WSL:

- `WSL_DISTRO_NAME` or `WSL_INTEROP` is set;
- the `WSLInterop` binfmt entry exists;
- `/proc/sys/kernel/osrelease` names Microsoft or WSL.

WSL kernels carry that name even with interop off. Only the live markers catch a custom WSL kernel
without it.

The reviewer commits each record at its `evidence_ref`, whether it passed or failed. A matrix row
changes only under the "Verdicts" conditions. Then `matrix_revision` is bumped and
`python -I parity/contracts/validate.py cache-qualification <matrix>` must pass.

## Deferred to P13 and P22

- Every runtime result: steps 1-10 for all 85 rows, plus the exact cl and link toolset version.
- Several items **to confirm in lab**:
  - the `session-end --json` layout;
  - the artifact store layout and the journal outcome of a rejected entry, for the poison step;
  - the daemon kill method;
  - pass-through for unsupported invocations other than rustc binary crates;
  - the clang-cl `/Zi /Fd` PDB behaviour;
  - journal and log growth;
  - whether a byte budget below the 40 GiB clamp is honoured.
- Running `tests/parity/cache/qualification/harness_test.sh` and shellcheck on real Linux. CI on
  hosted `ubuntu-latest` is a coordinator follow-up.
- `-g` rows for the non-default Linux compilers, which need a contract revision raising `maxItems`.
- The hardlink and reflink modes, and any sharing across worktrees ([retention.md](retention.md)).
