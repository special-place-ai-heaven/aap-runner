# zccache 1.15.6 qualification (P04)

**State: static qualification and harness only. No row is qualified. Every row is `direct`.**
This host runs the live production pool, and the authorized lab (gate D2) does not exist yet. So
no qualification run exists. The runtime matrix is a tracked follow-up that P13 and P22 run in the
lab with the harness below. Until a row qualifies, its compiler and invocation build directly with
no wrapper. Full parity must hold that way (contract rule 3). P04.1 ran the Linux harness against
the pinned binary in WSL to find harness defects ("Smoke runs outside the lab"). Those runs are not
evidence for any row.

| File | Purpose |
|---|---|
| [linux-x86_64.json](linux-x86_64.json), [windows-x86_64.json](windows-x86_64.json) | The matrices, one per platform, in the [cache-qualification contract](../../contracts/cache-qualification.md) shape |
| [artifacts.md](artifacts.md) | Release assets, digests, member hashes, verification steps and forbidden install paths |
| [retention.md](retention.md) | Retention, byte accounting, trust and isolation requirements for P13 and P16 |
| [harness/qualify.sh](harness/qualify.sh), [harness/qualify.ps1](harness/qualify.ps1) | The lab harnesses for Linux and Windows |
| [harness/record.jq](harness/record.jq), [harness/journal.jq](harness/journal.jq) | The verdict and the journal counter, shared by both harnesses |
| [harness/fixtures](harness/fixtures) | The C, C++ and Rust fixtures, each with a deliberate-error twin |

Tests live in `tests/parity/cache/qualification/`. Pester covers the Windows harness and
`record.jq`, and Python covers the matrices. `harness_test.sh` covers the Linux harness and needs
real Linux with bash, coreutils and jq. Hosted `ubuntu-latest` is enough, and the test needs no
zccache. `mutate.py` disables each P04.1 harness rule in a copy and requires the test written for
it to fail.

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
MinGW `gcc 15.2.0` on the Windows image and the clang bundled with Visual Studio (the P01 inventory
does not record its version).

## Rows

Compiler versions come from the P01 inventories, and a test ties them to those files.

| Platform | Compiler | Versions | Invocations | Rows |
|---|---|---|---|---:|
| Linux | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces | 3 |
| Linux | clang, clang++ | 16.0.6, 17.0.6, 18.1.3 | compile-object, compile-pch, response-file, depfile, path-with-spaces, debug-pdb (`-g`) | 36 |
| Linux | gcc, g++ | 12.4.0, 13.3.0, 14.2.0 | compile-object, compile-pch, response-file, depfile, debug-pdb (`-g`) | 30 |
| Windows | rustc | 1.99.0 | rustc-wrapper, link, path-with-spaces, debug-pdb | 4 |
| Windows | clang, clang++ | 20.1.8 | as Linux clang without debug-pdb | 10 |
| Windows | clang-cl | 20.1.8 | compile-object, response-file, debug-pdb, path-with-spaces | 4 |
| Windows | cl | VS 18.10.12224.181 | compile-object, compile-pch, response-file, debug-pdb | 4 |
| Windows | link, lld-link | VS 18.10.12224.181, 20.1.8 | link | 2 |

| Reason class | Rows |
|---|---:|
| Unqualified, pending lab | 85 |
| Direct per upstream binary-crate pass-through (rustc link, debug-pdb) | 3 |
| Direct-only, MSVC partial (cl, link) | 5 |
| Total (Linux 69, Windows 24) | 93 |

The contract has no separate `-g` class, so on Linux `debug-pdb` stands for DWARF `-g` output.
Those rows target the classic `DW_AT_comp_dir` cache hazard. P04 shipped them only for the image
defaults (clang 18, gcc 13) under the 64-row cap of contract revision 1. Contract revision 2 raised
the cap to 256, and P04.1 added them for every compiler version in matrix revision 2: clang and
clang++ 16.0.6 and 17.0.6, gcc and g++ 12.4.0 and 14.2.0. Each new row is `unqualified - pending
lab` like the rest. No WSL distro here carries those compiler versions, and WSL is not the lab.

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

- It runs every build and every zccache call with an empty stdin (`/dev/null` on Linux). The
  zccache client reads its stdin. A client that inherited a shell's open stdin waited on it forever
  before compiling (seen in WSL, P04.1).
- It removes every `ZCCACHE_*` variable inherited from the lab shell, including `ZCCACHE_ENDPOINT`,
  `ZCCACHE_PATH_REMAP` and `ZCCACHE_SESSION_ID`, and records the removed names. It sets only
  `ZCCACHE_MODE=COPY`, plus `ZCCACHE_CACHE_DIR` and `ZCCACHE_SESSION_ID` for each wrapped run. Every
  run records the `ZCCACHE_*` names in effect.
- On Linux it runs every build and every zccache call, and so the daemons, under `env -i` with an
  allowlist: `PATH`, `HOME`, `PWD`, `TMPDIR`, `LANG`, `LC_ALL`, `CARGO_HOME`, `RUSTUP_HOME`,
  `RUSTUP_TOOLCHAIN` and its own three `ZCCACHE_*` variables. A credential the name and value
  checks miss never reaches them. `PWD` stays because GCC takes `DW_AT_comp_dir` from it.
- It canonicalizes the work directory before building any path under it. Linux resolves symlinks
  in its parents (`pwd -P`). Windows uses long names in their on-disk case and refuses a work
  directory below a symbolic link or junction. Then it copies `zccache` and its sibling
  `zccache-fp` into a private `bin` directory there. It hashes the copies against the pins (exit 4
  on a mismatch) and runs only them, never the file named on the command line. The process helpers
  refuse an empty or relative `bin` path.
- For non-MSVC compilers, it checks that the `--version` banner names the matrix version (exit 2
  otherwise). It records the compiler's path and SHA-256.
- It gives every case its own fresh cache root: `cache-ok` for cold, warm and relocated builds,
  `cache-error`, `cache-poison-artifact`, `cache-poison-same-size` and `cache-poison-marker`. It
  never deletes a cache root.
- It runs every build with the working directory at the fixture tree.

zccache keeps its state one level below the root that `ZCCACHE_CACHE_DIR` names, in `v1.15.6/`
(`resolve.rs` `versioned_subdir` at the pin; observed in WSL). That folder holds the artifact
store, `crashes/`, `crash-spool/` and a copy of the `zccache` binary that zccache deploys as
`v1.15.6/zccache-daemon` and runs as the root's daemon (`cli/runtime/deploy.rs` 106-125). The
README's root layout (README 433-436) leaves the version folder out.

After the builds, the harness lists every visible `zccache*` process with its executable path and
SHA-256. It marks whether each runs from the private copy or from a deployed daemon copy at exactly
`<work>/cache-<case>/v1.15.6/zccache-daemon`. It counts every file in a `crashes/` folder below each
root (README 433-434) and every non-empty file in a `crash-spool/` folder. Each live zccache process
keeps an empty `pending-*.rpcrash` there, which a crash fills (`crash.rs` 24-34; seen on Linux, to
confirm on Windows). Then it stops every process running from the private copy or a deployed copy,
also after a failure. The dumps themselves never leave the VM. They can hold process memory and
environment.

1. **Uncached.** Build the fixture with the compiler directly, with no wrapper. Record the exit code
   and the SHA-256 of every file in the output directory. Every success-case build must produce
   its primary artifact, because two empty output directories would otherwise compare equal.
2. **Cold.** Build through zccache as `zccache <compiler> <args>` (README 359-366, 795-797) on a
   fresh root with `ZCCACHE_MODE=COPY`. For rustc this is the form `RUSTC_WRAPPER` produces. Exit
   code and artifacts must equal the uncached build. The cold session must record zero hits.
3. **Warm.** Remove the outputs and build again on the same root. Exit code and artifacts must be
   equal. **A green warm build counts as caching evidence only with at least one observed hit.**
   Hits come from the per-session journal. `zccache session-start --journal <file>.jsonl` prints
   JSON with `session_id` (README 1254-1273). Journal lines with `outcome` `hit` or `link_hit` count
   as hits (README 1240-1252). The harness keeps `zccache session-end <id> --json` output
   (README 1224-1229), but its layout is undocumented, so it is **to confirm in lab** and not used
   for the verdict. Without a session id, the journal is `null` and the row cannot pass.
4. **Poisoned cache, three variants.** Upstream does not claim to prove cache integrity
   (README 1123), so corruption handling needs its own evidence. Each variant gets its own root.
   The harness primes the root with one build through zccache and corrupts regular files under
   `<root>/v1.15.6/artifacts/`. It never follows a link or junction. Then it stops the daemons and
   builds again in a journaled session, so a fresh daemon reads the store from disk. In WSL the
   daemon alive since priming served a hit with correct bytes after every store file was replaced,
   which says nothing about the store.
   - `artifact` flips one byte in the middle of each store file whose SHA-256 equals an uncached
     artifact, in place. The file keeps its length and modification time, and nothing else in the
     store changes, so this variant asks whether zccache checks the content it serves. Upstream
     delivers hits as hardlinks or reflinks of the cache file (README 548-560), so the store should
     hold artifact bytes verbatim. In WSL it did, as `artifacts/.staged-v2/<key>/<hash>/output-0`.
     The lab confirms it per row. If no stored file matches, the variant corrupts nothing and fails.
   - `same_size` flips one byte in the middle of every file under `artifacts/` in the same way.
     Those files can include per-entry metadata, which a format check might reject without any
     content check. So a pass here does not by itself show that content is verified. What
     `artifacts/` holds besides artifact bytes is **to confirm in lab**.
   - `marker` replaces each file with the 10-byte `P04-POISON`, which changes its length.

   A variant passes when it meets all of these conditions:
   - at least one file was corrupted;
   - the priming build's exit equals the uncached build's exit;
   - the build's exit code and artifacts equal the uncached build;
   - the journal shows the invocation was looked up, with at least one `miss`, `error` or
     `link_miss` entry;
   - the journal shows no `hit` or `link_hit` and no unrecognised outcome. Upstream lists every
     outcome (README 1247), so an unknown one could be a hit under another name.

   A hit served from anywhere else, such as a staged generation outside `artifacts/` or warm
   daemon state, never counts as detection. The journal outcome for a rejected entry (`miss` or
   `error`) and the store layout, including staged generations (README 501-530), are **to confirm
   in lab**.
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
   `stop` command for the compile daemon. The harness record gives the daemon's process name and
   executable, so the kill method is **to confirm in lab** from that record.
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

The harness writes one JSON record per call. The verdict comes from `record.jq`, and the record
holds these fields:

- `command`: the harness invocation, without machine paths.
- `tool_versions`: the compiler's banner, path and SHA-256, zccache's version and SHA-256, the
  `zccache-fp` SHA-256, the jq version, and the prerequisite compiler for link rows. Values are
  printable ASCII of at most 120 characters, as the evidence bundle requires.
- `os`: the kernel release or Windows version, plus `ImageOS` and `ImageVersion` when the image
  sets them.
- `env`: the variables the harness set and the `ZCCACHE_*` names it removed.
- `runs` and `error_runs`: each with exit code, artifact hashes, argv, cache root name,
  `ZCCACHE_*` names in effect and journal counts.
- `daemons` (each with `in_private_bin` and `in_cache_root`), `daemons_stopped` and `crash_dumps`.
- `checks`, `harness_pass` and `lab_gates`.
- `row`: always `direct`.

The verdict requires all of these checks. Missing or mistyped input fails a check and never passes
one. Exits and counts must be numbers, hashes must be 64 hex digits, and two absent values never
compare equal.

| Check | Requires |
|---|---|
| `ok_exit_zero`, `ok_runs_produce_primary` | The uncached build succeeds, and every success-case build produces its primary artifact |
| `exit_codes_equal`, `artifacts_equal` | Cold and warm builds equal the uncached build |
| `cold_has_no_hits`, `warm_has_hits` | The journal shows no hit and no unrecognised outcome when cold, and at least one hit when warm |
| `errors_stay_errors` | Error-case builds keep the uncached non-zero exit and leave no primary artifact |
| `poisoned_artifact_rejected`, `poisoned_same_size_rejected`, `poisoned_marker_rejected` | Step 4 holds for each variant |
| `zccache_env_clean` | Every run records its `ZCCACHE_*` names as a list, and only the harness's own reached any build |
| `daemons_pinned` | At least one `zccache*` process was seen, and every one ran from the private copy or a deployed daemon copy in one of the harness's roots, with a pinned hash |
| `no_crash_dumps` | Crash files were counted for at least one cache root, and every count is zero |
| `tool_versions_recorded` | `tool_versions` holds every field above as printable text |
| `compiler_version_observed` (non-MSVC) | The recorded banner names the matrix version |
| `relocated_matches_direct` (debug-pdb) | The relocated build equals its direct build |

The record holds no log body and no environment value from the lab shell. P13 and P22 wrap each
record in an evidence bundle per [evidence-cleanup.md](../../contracts/evidence-cleanup.md). They
add `head_sha`, `contract_revision` (`cache-qualification@1`), `os_version`, `verifier` and the
remaining bundle fields. They copy `command`, `tool_versions` and the `os` values from the record.

## Running the harness (lab only)

The harness needs jq 1.7 or later, which both baseline images ship, and `zccache-fp` beside
`zccache`. Start it from a clean shell. No token, key, password, URL with credentials or runner JIT
config may be in the environment, because the daemon and its crash dumps inherit that environment.
The harness refuses with exit 3 and names the variables, never their values. The work directory
must be new or empty, and it must not be a symbolic link or junction. Use a fresh per-user
directory, never a shared `/tmp` path or a fixed folder like `C:\zq`.

```bash
export AAP_ZCCACHE_LAB=1   # only inside the disposable lab VM
work=$(mktemp -d "${XDG_RUNTIME_DIR:-$HOME}/zq.XXXXXX")
parity/cache/qualification/harness/qualify.sh clang /usr/bin/clang-18 18.1.3 compile-object \
  "$HOME/zccache-1.15.6/zccache" "${work}.json" \
  parity/cache/qualification/evidence/linux-x86_64/clang-18.1.3-compile-object.json "${work}"
```

```powershell
$env:AAP_ZCCACHE_LAB = '1'   # only inside the disposable lab VM
$work = Join-Path $env:LOCALAPPDATA ('zq-' + [guid]::NewGuid().ToString('N'))
.\parity\cache\qualification\harness\qualify.ps1 -Compiler clang-cl -CompilerPath 'C:\Program Files\LLVM\bin\clang-cl.exe' `
  -CompilerVersion 20.1.8 -Invocation compile-object -Zccache "$env:LOCALAPPDATA\zccache-1.15.6\zccache.exe" -Out "$work.json" `
  -EvidenceRef parity/cache/qualification/evidence/windows-x86_64/clang-cl-20.1.8-compile-object.json -Work $work
```

| Exit | Meaning |
|---:|---|
| 0 | Record written; read `harness_pass` |
| 1 | Unexpected harness error; no record |
| 2 | Usage: bad arguments, a banner that does not name the version, or no jq |
| 3 | Refused: not a clean lab |
| 4 | `zccache` or `zccache-fp` is not the pinned release binary |

Refusal comes first, before any argument is read. Both harnesses refuse in these cases:

- `AAP_ZCCACHE_LAB=1` is not set.
- A live-install marker exists. On Linux these are `/etc/aap-runner`, `/var/lib/ghrunner` and
  `/sys/fs/cgroup/aap.slice/aap-runner.slice`. On Windows they are `%ProgramData%\aap-runner`,
  `%ProgramFiles%\aap-runner`, `%ProgramW6432%\aap-runner` and `%SystemDrive%\wsl`. ProgramW6432
  matters when a 32-bit PowerShell maps ProgramFiles to Program Files (x86).
- A variable name looks like a credential. That covers token, secret, pass, credential, JIT, JWT
  and private key anywhere in the name, PAT and AUTH as whole words, and names ending in KEY, PEM
  or `_PWD`. Examples are `GH_PAT`, `DB_PASS`, `NPM_CONFIG__AUTH`, `SSH_AUTH_SOCK`, `CI_JOB_JWT`
  and `MYSQL_PWD`, while `PATH`, `PWD` and `GIT_AUTHOR_NAME` pass.
- A variable's value carries URL credentials, `scheme://user:password@host`, whatever the variable
  is called. Examples are `DATABASE_URL` and `HTTPS_PROXY`.

The Linux harness also refuses on signs of WSL:

- `WSL_DISTRO_NAME` or `WSL_INTEROP` is set.
- Any `/proc/sys/fs/binfmt_misc/WSLInterop*` entry exists. Systemd distros register
  `WSLInterop-late`.
- `/proc/sys/kernel/osrelease` names Microsoft or WSL. WSL kernels do even with interop off, and
  inside containers, which share the kernel.

Only the live markers catch a custom WSL kernel without that name.

The reviewer commits each record at its `evidence_ref`, whether it passed or failed. A matrix row
changes only under the "Verdicts" conditions. Then `matrix_revision` is bumped and
`python -I -B parity/contracts/validate.py cache-qualification <matrix>` must pass.

## Smoke runs outside the lab (P04.1, not evidence)

On 2026-10-21 P04.1 ran `qualify.sh` in WSL Ubuntu-24.04 against the pinned Linux archive, with
its hash checked. A driver outside the repository skipped the clean-lab gate. The compiler was
`gcc-13` 13.4.0, which is not a matrix version. The runs tested only the harness, and they found
five defects, fixed here:

- the daemons ran from the deployed copy in each root, so `daemons_pinned` always failed and no
  daemon was stopped;
- the store and the crash folders sit in `v1.15.6/`, so the poison step corrupted nothing and the
  crash-dump count was always zero;
- the poisoned build was served by the daemon still alive from priming;
- a compiler argv that starts with `-c`, `-g` or `-x` broke the record's `jq` call, because jq
  still parses options after `--args`;
- an open stdin hung the zccache client before it compiled.

After the fixes, `compile-object` passed every step 1-6 check. The cold build missed and the warm
build hit. All three poison variants were rejected as a `miss`, and the error case stayed an
error. `debug-pdb` (`-g`) did not pass. The cold and warm objects differed from the direct build,
because zccache adds `-H` to the GCC compile and GCC records its switches in `DW_AT_producer`
(`-grecord-gcc-switches` is on by default). The relocated build missed, so no stale
`DW_AT_comp_dir` was served. A GCC `-g` row therefore needs the documented semantic comparison
("Equivalence") or stays `direct`. The lab confirms this for each matrix version.

## Deferred to P13 and P22

- Every runtime result: steps 1-10 for all 93 rows, plus the exact cl and link toolset version.
- Several items **to confirm in lab**:
  - the `session-end --json` layout;
  - the artifact store layout and the journal outcome of a rejected entry, for the poison step
    (in WSL a rejected entry showed as a `miss` once the daemon had restarted);
  - whether the store holds artifact bytes verbatim and what else `artifacts/` holds, for the
    `artifact` and `same_size` variants;
  - the `crash-spool/` and deployed-daemon layout on Windows;
  - the daemon kill method;
  - pass-through for unsupported invocations other than rustc binary crates;
  - the clang-cl `/Zi /Fd` PDB behaviour;
  - journal and log growth;
  - whether a byte budget below the 40 GiB clamp is honoured.
- The hardlink and reflink modes, and any sharing across jobs or worktrees
  ([retention.md](retention.md)).
