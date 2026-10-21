# zccache guest integration (P13)

Packages the pinned zccache 1.15.6 into the Windows and Ubuntu guest images and decides, per compiler call, whether a
build goes through zccache or straight to the compiler. Contract:
[cache-qualification.md](../../parity/contracts/cache-qualification.md) (revision 2; rule 6 as amended on 2026-10-20:
`workflow_dispatch` is untrusted, untrusted jobs get a private per-job root only). Requirements:
[retention.md](../../parity/cache/qualification/retention.md) (requirement 4 is superseded by contract rule 6). What
other items must wire: [INTEGRATION.md](INTEGRATION.md).

**State at the pin: no compiler and invocation pair is qualified (P04: all 85 rows `direct`), so the integration
installs and verifies zccache, creates the bounded per-job root and turns on nothing.** Every build compiles directly,
which is the correct and required behaviour until P04/P22 qualify a row in the lab. **Shared roots are off** until the
lab proof for them exists, whatever is qualified. Nothing here was run against a real zccache binary or a real
compiler; the tests use the doubles in `tests/guests/cache/fakes`.

## Licence: internal use only

zccache is **AGPL-3.0-only** (Cargo.toml, README and LICENSE at commit `15ec953`). Running it on the owner's runners
is internal use. An image that contains the binary must not leave the owner's hosts (no export, sharing or publication
of a generation) until the owner records a compliance decision; AGPL section 13 adds source-offer duties for network
use. P13 does not make that decision. P21 carries the constraint into the image catalog.

## Files

| File | Role |
|---|---|
| `wrappers.json` | The one qualified-wrapper manifest for both platforms: pinned archive and members, the P03 entry that delivers the archive, and only the `qualified` matrix rows. Generated; never edit by hand |
| `gen_wrappers.py` | Generator (`python -B -I guests/cache/gen_wrappers.py [--check]`). Each matrix must pass `parity/contracts/validate.py`; the zccache member hash must equal the matrix `binary_sha256`; the P03 manifest must pin the same archive, size and hash; a qualified row needs committed evidence |
| `windows/AapZcCache.psm1` | Windows: `Install-AapZcCache`, `Initialize-AapZcJob`, `Connect-AapZcSharedRoot`, `Get-AapZcState`, `Invoke-AapZcShim` (PowerShell 5.1 and 7) |
| `windows/zcshim.ps1` | Windows compiler launcher, run by PowerShell 7: `pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File zcshim.ps1 <compiler> [args]` |
| `linux/aap-zccache.sh` | Linux: `install`, `init`, `attach`, `state`; installed a second time as `zcshim`, the launcher |
| `host/AapCacheTrust.psm1` | For the host (P12/P16): `Select-AapCacheJob` (the one job GitHub assigned to this runner) and `Get-AapCacheTrustClass` (contract rule 6 from GitHub's records) |

## How it works

1. **Install (image build).** Input is the archive P03 staged (`images/common`, entries
   `zccache-x86_64-pc-windows-msvc` and `zccache-x86_64-unknown-linux-musl`) with its `<file>.provenance.json`. The
   provenance must say accepted, hash verified, strict staging, this entry, version and hash. The installer then hashes
   the archive itself (Windows hashes and unpacks the same bytes in memory; Linux works on one private copy, removed on
   exit), refuses any member with an absolute path, a `..` segment, a link type or (Windows) a drive letter, extracts
   only the two pinned members (`zccache`, `zccache-fp`) and checks each one's size and SHA-256. Nothing is
   downloaded, and no install script, `releases/latest`, crate or upstream Action is used (artifacts.md, "Forbidden
   install and restore paths"). It also records the image's compilers (`toolchains.json`: compiler, version, path,
   SHA-256, size, modification time) and their digest in `install.json` for the image catalog.
2. **Initialize (guest agent, before the Actions runner starts).** Re-hashes the installed binaries and every
   toolchain; a mismatch disables the cache or drops that toolchain. Creates the per-job root
   (`state/`, `roots/private/`, `shim/`). Only if a qualified pair can be wired does it start the private root's
   daemon (from the agent's environment, never a job step's; on Linux under `env -i` with the P04 harness allowlist:
   `PATH`, `HOME`, `PWD`, `TMPDIR`, `LANG`, `LC_ALL`, `CARGO_HOME`, `RUSTUP_HOME`, `RUSTUP_TOOLCHAIN`) and write
   `state/runner.env` for the runner: `AAP_ZC_STATE`, plus `CMAKE_C_COMPILER_LAUNCHER` / `CMAKE_CXX_COMPILER_LAUNCHER`
   for C/C++ pairs and, on Linux, `RUSTC_WRAPPER` for rustc pairs. No `ZCCACHE_*` variable is ever set for jobs. With
   nothing wired the file is empty. Options: shared roots (`-SharedRoots` / `--shared-roots`, **off**; see "Trust and
   namespaces") and the bounds on each wrapped call: `-WrapperTimeoutSeconds` / `--wrapper-timeout` (60 s) for an
   object compile (`compile-object`), `-WrapperTimeoutLongSeconds` / `--wrapper-timeout-long` (600 s) for every other
   call (a whole-crate `rustc`, a link, a precompiled header routinely runs for minutes).
   On Windows the launcher is PowerShell 7 (`pwsh.exe`): Windows PowerShell 5.1's `-File` refuses a bare `-` argument
   (a compiler reading stdin) before the script runs, which would fail the compile itself. Without PowerShell 7 nothing
   is wired. `RUSTC_WRAPPER` is never wired on Windows (INTEGRATION.md, gap G3).
3. **The shim, per compiler call.** It builds directly unless **all** of these hold: the job state exists and is
   `qualified`; the compiler path is a recorded toolchain whose size and modification time still match (the full hash
   is checked once per boot); the call's invocation classes can be determined and **every** one is qualified for that
   compiler and version (a `-g` compile needs `debug-pdb` qualified as well as `compile-object`); the active root is
   not marked degraded; the root is within budget; its daemon is alive (same PID and start time as recorded). Then it
   runs the install's own `bin/zccache` (never a path from the job's config) as `zccache <compiler> <args>` with the
   job's environment minus every inherited `ZCCACHE_*` variable and anything credential-shaped (names come from the
   whole environment block, including names no shell variable can hold), plus `ZCCACHE_CACHE_DIR`, `ZCCACHE_MODE=COPY`
   and `ZCCACHE_CACHE_SIZE_BYTES`. That call is bounded (60 s for an object compile, 600 s otherwise, by default): past
   the bound it is killed with every process it started (Windows: the process tree; Linux: `timeout` kills the
   client's process group), and the root's daemon is stopped with its children before the direct compile, because it
   may still be compiling the same output file; nothing late can then overwrite the direct result. Output is held
   back; on **any** non-zero exit or timeout (compile error, crash, hang, daemon or transport failure, rejected entry)
   the shim runs the compiler directly and returns its exit code and output, so an error is reported once and a build
   that would pass directly never fails because of the cache. The price: a compile error costs two compiler runs. If
   the direct run succeeds the root is marked `wrapper-failure` (a timeout: `wrapper-timeout`, either way) and not used
   again in this VM.
   **Delivery check.** zccache's exit 0 is not taken on trust. The shim names the outputs of each call (the `-o` file;
   the depfile of `-MD`/`-MMD`: its `-MF`, or the `-o` name with its last suffix replaced by `.d`, as gcc and clang name
   it; clang-cl's `/Fo` file, `/FoNAME`, `/Fo:NAME` or `/Fo: NAME`, with `.obj` added to a name without an extension)
   and removes them before the call, so a stale file from an earlier build cannot pass for this one. After a zero exit
   each must be a non-empty regular file, not a link or other reparse point, and on Linux not a hard link (link count
   1; COPY mode never makes one); otherwise the call counts as failed: the root is marked `delivery`, its daemon is
   stopped (it may still be copying that output), whatever zccache left at those paths is removed (a link into the
   root would be written through) and the compiler runs directly. A call whose outputs cannot be named (no single
   `-o` or `/Fo` file, `-o -`, `/Fo` naming a folder or nothing, several `-MF`, or a depfile asked for in another
   spelling: `-Wp,-MD,FILE`, `-Xpreprocessor`, `--write-dependencies` and the other long `--*dependencies` forms,
   clang-cl's `/clang:-M...`; a call that writes sidecars the shim does not check: `-MJ`, `-save-temps`, `--coverage`,
   `-ftest-coverage`, `-fprofile-arcs`, `-fprofile-generate`, `-gsplit-dwarf`, clang-cl's `/sourceDependencies`; on
   Windows an output that is a device: `NUL`, `CON`, `PRN`, `AUX`, `COM1`-`COM9`, `LPT1`-`LPT9` with or without an
   extension in any case, or a `\\.\` or `//./` path) builds directly (`outputs-unknown`) without marking the root. This proves delivery, not that the bytes are right: that stays with the trust rule and P04's evidence.
   **Residual:** rustc calls, whose outputs follow `--out-dir`, `--emit`, the crate name and `-C extra-filename`, and
   clang-cl's `/Fd` PDB are not named, so they rely on zccache's own delivery. At the pin that is the same COPY materialization as for objects (entries published by
   temporary file and rename, a hit copied from one open into a new file that is removed on error, a failed delivery
   compiled instead: `persist/artifact_io.rs:63-95`, `zccache-core/src/config/materialization_mode.rs:137-151`,
   `handle_compile/pipeline/mod.rs:550-551`), and P04's qualification of each rustc pair (rule 4: equal outputs over
   cold and warm builds, kill and restart) is the evidence it holds. No pair is qualified at the pin.
   **Accepted residuals** (P13.3 reviews): (a) two writers of the same output path inside one VM can interleave with
   the shim's removal, check and fallback; that is a build-system bug and stays inside that VM; (b) Windows does not
   check the link count, so a hard-linked output passes the check there; `ZCCACHE_MODE=COPY` on every call is the
   control; (c) Windows `link` and `lld-link` outputs are not checked (declared outputs are empty, like rustc's);
   (d) the daemon binary zccache deploys into a root is not hash-checked ("Daemon discovery" below; P22).
   **Progress lines.** zccache's client writes `zccache[info][Q]: daemon under load: ...` to stderr while a compile
   waits or runs (`cli/commands/wrap/ipc.rs:347-366`), before the compile's own stderr. On a zero exit the shim drops
   that leading run of exact progress lines and passes everything after it on byte for byte. The documented switch
   (`ZCCACHE_COMPILE_PROGRESS_INTERVAL_MS=0`, `daemon/server/connection/mod.rs:44-55, 133-157`) is not used: the
   heartbeats also keep the client's 180 s wedge budget and 300 s receive timeout alive, so without them any compile
   longer than that would be taken for a hung daemon. The Windows launcher takes the arguments from the process command line as Windows splits it, not
   from PowerShell's parameter parsing, which splits `-std:c++17` and drops `--%` or `-a:`; a direct compiler shares
   the shim's console and standard handles.
4. **Attach (guest agent, when the host binds a shared root).** See "Trust and namespaces". The function takes the
   install folder, a binding record file the agent received over the management transport and the folder where it
   mounted the disk the host attached; it reads nothing from the environment. On any refusal the job keeps its private
   root.
5. **State.** `Get-AapZcState` / `aap-zccache.sh state` return `qualified`, `direct`, `disabled`, `degraded` or
   `unknown` with a printable detail of at most 200 characters (the `status.v5.json` `cache` object) and byte counts
   per root, artifacts separate from everything else, plus the shim's own bytes.

Daemon discovery: zccache 1.15.6 deploys a copy of itself into the root, `<root>/v1.15.6/zccache-daemon[.exe]`, and
runs its daemon from there (`cli/runtime/deploy.rs:106-125`); only when that copy fails does it run the daemon in
place from the installed `bin` folder. After priming a root, the daemon is the one process running from either that
belongs to the root. Linux reads it from the process environment (`ZCCACHE_CACHE_DIR` equal to the root). Windows
cannot read another process's environment without native code, so it takes processes from those paths started during
the priming and excludes every compile client (each names a recorded compiler on its command line). None or several
candidates: every candidate is stopped and the root is not used. The deployed copy (27 MB on Linux, 24 MB on Windows)
lives in the root and counts against the root's non-artifact quarter of its budget like everything else there; a
budget below about 128 MiB leaves no room for it, and the root is over budget from the first call. The lab records the daemon's own command line (P22), which then allows
an exact match on Windows.
**The deployed copy is not hash-checked.** The installer and every boot check the installed `bin` members against the
pin, but the copy zccache deploys into the root is zccache's own and nothing here hashes it: a root a job can write
could hold a substituted `zccache-daemon` that zccache then runs. A private root is the job's own; before any shared
root (MEDIUM), P22 adds the check: hash `<root>/v1.15.6/zccache-daemon[.exe]` against the pinned member before priming
and delete it or refuse the root otherwise.

Invocation classes come from the arguments (response files are expanded one level; a nested one is not classified):
`-c`/`/c` is required; `-E`, `-S`, `-M`, `-MM`, `-fsyntax-only`, `-###`, `--print*`, `/E`, `/P`, `/EP`, `/Yu`, a stdin
source (`-`), a driver link without `-c`, rustc probes (`-vV`, `--print`, stdin) and any compiler not in the matrix
(nvcc, emcc, MinGW gcc on Windows) are not classified and build directly. The shared vectors are in
`tests/guests/cache/fixtures/classify.json`.

## Trust and namespaces

The enforcement point is the **host**: it decides which disk it attaches to which VM, and only after it has the job's
trust class from GitHub's records of the job assigned to that runner (INTEGRATION.md names the API calls, the token and
the permission decision). Only `trusted` (contract rule 6 as amended: `push` or `schedule` on the default branch, the
head commit being that branch's head when the class is bound, the repository itself as head repository) ever gets a
shared root; **every untrusted job gets only its private root**. A job runs with admin/sudo inside its guest, so nothing inside the guest can stop it
from writing whatever is attached; the guest-side checks catch mis-wiring.

**Shared mutable roots stay off until the lab proof exists** (P04/P22: the concurrency, poisoning and
direct-equivalence runs retention.md requirement 5 asks for, on a shared root). Until then the host must not bind, and
the guest refuses every binding: shared roots are enabled only by `Initialize-AapZcJob -SharedRoots` /
`init --shared-roots`, which P14/P15 pass only after that proof.

`Connect-AapZcSharedRoot` / `attach` refuse, and keep the private root, when: nothing is qualified; shared roots are
off (`shared-roots-off`); a shared root is already bound; the binding is missing, unreadable or lacks a field (no class
means no shared root); the class is not `trusted` (`not-trusted`, whatever the disk's marker says); the binding names
another runner; it is for another platform, toolchain digest or zccache version; the mount or its `root` folder is a
link; the budget is not positive; the disk's `aap-cache-root.json` marker does not name the same root id and all six
namespace fields; or the root's daemon cannot be identified.

The contract's namespace key is the repository id, the trust class, the zccache version and the toolchain digest
(SHA-256 of the sorted `compiler|version|sha256` lines, identical on both platforms). Bindings and markers also carry
the repository name and the platform, and the guest compares all six fields: a stricter key, never one that merges what
the contract separates. Entries made by one set of compilers or one zccache release are never served to another,
whatever zccache's own key holds.

| Namespace | Key | Writers and readers | Trust | Retention owner | Ends |
|---|---|---|---|---|---|
| Per-job private root | reservation (one VM) | the one job | n/a | the daemon (artifact budget); the VM's destruction removes it | with the VM |
| Trusted shared root (off until the lab proof) | repository id + `trusted` + platform + toolchain digest + zccache version | trusted jobs of that repository, **one VM at a time** (exclusive read-write lease, P12) | `trusted` only | the daemon inside its budget; whole-root reset and deletion by P25 from host-measured size; the disk lives in a host cache tier P12/P19 own | digest or version change, repository removed from the runner group, or a P25 reset |
| Legacy distro compile cache | P16 | the legacy pool, unchanged until approved cutover | P16 | P16 (no purge) | cutover |

There is no untrusted shared root. No two VMs share one mutable root at the same time, so no daemon index is shared
across processes on different machines and `ZCCACHE_ENDPOINT` is never set. A second concurrent trusted job of the
same repository gets the private root.

## Retention, budget, logs and temp

- **No eviction by this code.** Retention inside a root is the daemon's (README 439-462), with an explicit
  `ZCCACHE_CACHE_SIZE_BYTES` of 3/4 of the root's budget. The other 1/4 is the cap for everything outside the artifact
  store: index, metadata, zccache's logs, journals, staging, crash dumps, `tmp/`.
- **The budget is the root's.** `BudgetBytes` / `BUDGET_BYTES` covers `roots/private`. The job root's `state/` (a few
  KiB) and `shim/` (the log, at most about 2 MiB, flag and stamp files, and the captured output of each call in
  flight, removed after the call) come on top; P10/P11 size the scratch disk with that margin.
- **Over budget means stop, not trim.** At most every 30 s per root the shim measures the root (links not followed).
  If the total exceeds the budget or the non-artifact bytes exceed their cap, the root is marked `over-budget` and
  every later call builds directly. No file is deleted. The hard ceiling is the scratch disk's maximum size (host). A
  measurement stamp the shim cannot write marks the root `usage-unwritable` instead, silently.
- **Clearing** is retention.md requirement 8: stop the root's daemon and delete the whole root (private: the VM goes;
  shared: P25 on the host). Never oldest-file eviction, never a partial trim.
- **Logs.** The shim writes one line per call (time, decision, compiler file name, exit code; no arguments, no
  environment) to `shim/shim.log`, rotated once at 1 MiB to `shim.log.1`, so at most about 2 MiB. Nothing the shim
  does writes to the compile's stderr. zccache's own logs and journals count against the root's non-artifact cap.
  zccache's crash dumps stay in the root of the daemon that wrote them (so inside the VM, or on the namespace disk)
  and are reported only as counts, never their contents.
- **Temp.** The shim's captured output files live in `shim/` and are removed after each call. zccache's `tmp/` is inside
  the root and counted.

## Threat model

| Threat | Control |
|---|---|
| A tampered or substituted zccache archive or binary | P03 provenance (strict run) plus the installer's own archive and member hashes; re-hash at every boot; any mismatch disables the cache; the shim runs only the install's own `bin` member |
| Archive path traversal or link members | members with absolute paths, `..`, drive letters or link types refuse the whole archive; only the two pinned members are extracted |
| Untrusted job poisons a cache a trusted job reads | the host attaches a shared root only for a `trusted` class from GitHub's records; there is no untrusted shared root; the guest refuses any non-trusted binding and any marker/binding mismatch; shared roots are off until the lab proof |
| A forged trust record (wrong job, wrong repository, a tag named like the default branch) | the host matches the job by runner id and runner group (exactly one), requires the run's repository to be the repository it looked up, and trusts only a run whose head commit is the default branch's head when the class is bound, in a repository the owner enabled (a tag push looks like a branch push in GitHub's run record, so a tag or re-run at any older commit is untrusted); anything incomplete means no class and no shared root |
| Hardlink poisoning (a build step writes into a delivered output that shares an inode with the store) | `ZCCACHE_MODE=COPY` on every call, overriding whatever the job set; hardlink and reflink stay off until P04/P22 prove them |
| A well-formed malicious entry in a root | out of reach of any integrity check (README 1123); bounded by the trust rule: only equally trusted writers share a root |
| A corrupted entry, a crashing or hung daemon | any zccache failure is answered by the direct compiler; a call past its bound is killed; the root is marked degraded |
| zccache exits 0 without its outputs (a bug, a full disk, an interrupted copy, a hostile entry), or a stale output from an earlier build | the shim removes the outputs it can name before the call and requires each to be a non-empty regular file after it; otherwise the root is marked `delivery` and the compiler runs directly; rustc and unnamed sidecars rely on zccache (residual above) |
| A substituted daemon copy in a root (`<root>/v1.15.6/zccache-daemon`, deployed by zccache and run from there) | not checked yet: a private root is the job's own; before any shared root P22 hashes the copy against the pinned member before priming and deletes it or refuses the root (MEDIUM) |
| A compile client recorded as the shared root's daemon | daemon discovery takes only the root's own process (Linux: its environment names the root; Windows: compile clients excluded) and refuses ambiguity |
| Credentials reaching the daemon or its crash dumps | daemons start from the guest agent before Actions (Linux: `env -i` with an allowlist); every zccache call drops credential-shaped names, URL-credential values and inherited `ZCCACHE_*` variables |
| Daemon PID reuse | liveness compares PID and process start time |
| Toolchain swapped under a root | full hash per boot, size and mtime per call, digest bound into the namespace |
| A job edits `AAP_ZC_STATE`, the config, the shim or a compiler | the job already has admin in its own VM; it can only affect its own job and whatever root the host attached for its class |
| Arguments mangled on the way to the compiler | the Windows launcher reads the process command line and re-quotes each argument for `CommandLineToArgvW`; tested end to end through the real launcher |
| Disk exhaustion | root budget, stop-at-cap, the scratch disk maximum; shared disks have a fixed maximum size set by the host |
| A daemon that inherits a captured pipe hanging the caller | Windows waits at most 10 s for the pipes after the process exits; Linux primes the daemon with output to a file; every wrapped call is bounded |

## Tests

| Suite | Command | Covers |
|---|---|---|
| Pester 5 (Windows PowerShell 5.1 and 7) | `Invoke-Pester tests/guests/cache/AapZcCache.Tests.ps1` | install refusals, init, shim with real processes through the real launcher (cold, warm, error, unsupported, concurrent, daemon down, PID reuse, crash, hang past the bound, corrupted entry, hardlink poisoning, over budget, log bound, exact arguments), attach (trusted, shared roots off, untrusted never, missing class, every refusal, a compile running during the attach, an ambiguous daemon), delivery (exit 0 without an object or depfile, with and without a stale file, on a miss and a hit; an empty object; a link at the output, a reparse point by a stand-in; the daemon stopped; unnamed outputs, other depfile spellings), zccache's progress lines, the daemon at its deployed path, state, classes, declared outputs, argument quoting, job selection and trust class |
| bash (hosted `ubuntu-latest`; Git Bash runs it too, without the symlink cases) | `bash tests/guests/cache/zccache_test.sh` | the same cases for Linux (and a hard link at the output), plus the daemon's `env -i` start, names no shell variable can hold, the rustc `RUSTC_WRAPPER` wiring and a response-file call |
| Python | `python -B -I -m unittest discover -s tests/guests/cache -p "test_*.py"` | generator: current, nothing qualified, pins, qualified rows, every refusal |
| Mutation proof | `python -B -I tests/guests/cache/mutate.py [--suite pester\|bash\|python]` | disables each `SAFETY:<id>` check in a copy (some in more than one way) and requires the tests tagged with that id to fail |
| Lab (P22, real zccache, not a suite) | `bash tests/guests/cache/lab/real_zccache_stress.sh ARCHIVE ITERATIONS [CALLS] [STAGGER_MS] [LOAD] [TEAR]` | the real pinned archive, install, init and shim with the distro's gcc: concurrent calls on one root, each over a stale object and depfile, compared with a direct compile; any fallback fails the run |

None of this is in CI yet; adding `tests/guests/cache` to the Pester run path and the bash and Python suites to the
hosted Ubuntu job is a coordinator change (INTEGRATION.md).

## To confirm in the lab (P22, gate D2)

- The daemon start: an empty `session-start`/`session-end` starts the daemon on demand, from
  `<root>/v1.15.6/zccache-daemon` (seen on Linux with the real archive, P13.3). Confirm it on Windows and record its
  command line, so Windows can match it exactly instead of excluding compile clients.
- Whether zccache's daemon spawn inherits a client's stdio handles (a wrapped call that restarts the daemon must not
  hang the build), and whether zccache passes the client's environment to the compiler.
- Run `lab/real_zccache_stress.sh` on the lab's disks (8 and 32 concurrent calls, staggered and at once, under CPU
  load): no fallback and no bad output. The shim now checks the outputs it can name (P13.3), so a zccache that exits 0
  without them costs a direct compile and marks the root; rustc pairs and unnamed sidecars still rely on zccache, so
  P04's evidence for each rustc pair must show its outputs delivered.
- The deployed daemon copy in each root (27 MB on Linux, 24 MB on Windows) against the root budgets the host picks:
  it counts against the non-artifact quarter.
- Before any shared root: hash the deployed daemon copy against the pinned member before priming, and delete it or
  refuse the root when it differs (it is not checked today).
- Whether a byte budget below upstream's 40 GiB clamp is honoured, and the real non-artifact growth per root (the 3/4
  split is a starting value).
- Journal and log growth on a long-lived shared root, and `zccache clear`'s effect on them.
- The 60 s and 600 s wrapper bounds against the slowest qualified object compile and the slowest qualified rustc or
  link call (a bound that kills real compiles only costs time, but marks the root degraded).
- zccache's journals, logs and crash dumps in a shared root contain no environment and no argv (a trusted job's
  secret on its command line must not be readable from the namespace disk).
- The Windows launcher: CMake accepts the PowerShell 7 launcher list; per-call PowerShell start-up cost;
  `RUSTC_WRAPPER` needs one executable and is not wired on Windows (INTEGRATION.md G3).
- The shared-root proof itself (concurrency, poisoning, direct equivalence on a shared root) before any agent passes
  `-SharedRoots` / `--shared-roots`.
