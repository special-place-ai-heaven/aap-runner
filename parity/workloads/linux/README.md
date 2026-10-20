# Linux, Actions and xwin compatibility workloads (P18)

Real build workloads for the `ubuntu-24.04` profile, the Linux twin of `../windows` (P17). Each one compiles, links,
runs and inspects a tiny self-contained project the way a hosted job would, against an oracle taken from the frozen
baseline (`parity/baselines/ubuntu-24.04-x64`, runner-images build `7e7dc1b`, image `20261012.334.1`). Each has a
negative control: the same workload with a deliberately missing header, library, environment variable, tool,
compiler feature, service or registry entry, which must fail with a named first error. This leaf closes on
hosted-reference oracle validation and those negative controls; running them on the local candidate is P22/P24.

## Run

```bash
bash parity/workloads/linux/invoke-workloads.sh                     # all qualified, into $PARITY_OUT or $RUNNER_TEMP/parity-out
bash parity/workloads/linux/invoke-workloads.sh --list
bash parity/workloads/linux/invoke-workloads.sh --name linux/gcc,actions/linux --out /tmp/out
```

Hosted validation: `gh workflow run parity-workloads.yml --ref main -f ref=<branch> -f profile=ubuntu-24.04
-f entry=parity/workloads/linux/invoke-workloads.sh [-f args='--name linux/gcc']`. The entry is bash; it runs
`invoke_workloads.py` with the system `python3`, which runs `tools/parity-certify/certify.py run-workloads`.

`--name` takes ids or prefixes (`linux/gcc` selects `linux/gcc` and `linux/gcc.neg-*`), as several values or one
comma-separated string; a name that matches nothing, or an empty selection, is an error. `--out` must be new or empty.
Exit code 0 means every selected workload passed its oracle. Without `--name`, the definitions the oracle lists under
`unqualified` are not run and `summary.json` records why; naming one runs it, and it fails honestly.

`actions/linux/file-commands` needs the composite action to have run earlier in the same job:

```yaml
- uses: ./parity/workloads/actions/linux/file-commands
- run: bash parity/workloads/linux/invoke-workloads.sh
```

Certifying a candidate (P22/P24) passes only the qualified definitions to `certify.py`, the ones a run without
`--name` selects; the unqualified ones would fail there by design.

Workloads that change or query machine state (`linux/containers`, `linux/services`, `actions/linux/runner-env`,
`actions/linux/file-commands`) run only inside an Actions job (`GITHUB_ACTIONS=true`); elsewhere they fail with
`not inside a GitHub Actions job`. The others need no root and no network and also run on a developer's Linux.

Output folder:

| Path | Content |
|---|---|
| `defs/` | the selected definitions, as run |
| `results.json`, `logs/` | `tools/parity-certify` results and logs; usable as `--reference-results` for `certify.py certify` |
| `workloads/<id>.json` | per workload: definition oracle, observed facts, exit code, first error, artifacts with sha256, duration, image identity, source sha |
| `observed/` | the facts each workload checked (expected, observed, ok) |
| `artifacts/<id>/` | the hashed artifacts (`report.txt`; the xwin PE and its hand-off record) |
| `summary.json` | pass count, one row per workload, `unqualified_not_run`, and `tree`: the content manifest of the workloads, oracle and harness that ran (`tree_manifest.py`) |
| `work/` | build trees; removed after the run unless `--keep-work` |

Workloads keep the caches they control in their work folder (TMPDIR, XDG_CACHE_HOME, CARGO_HOME, GOCACHE/GOPATH,
NUGET_PACKAGES, DOTNET_CLI_HOME, GRADLE_USER_HOME, pip `--target`). Nothing is downloaded: cargo runs `--offline`,
Go has `GOPROXY=off GOTOOLCHAIN=local`, NuGet has no package source, pip runs `--no-index`, Gradle runs `--offline`
with core plugins only, containers are `FROM scratch` (nothing is pulled), and registry configuration is read, never
fetched. Maven is not driven (its first build downloads plugins), nor is sdkmanager (it contacts Google). npm's
cache and logs, Gradle's and .NET's homes and headless Chrome's profile are in the work folder too, and Chrome runs
without background networking or component updates.

What stays on the machine after a run: `linux/containers` removes its service container, user network and image
(`docker rm -f`, `docker network rm`, `docker rmi -f`, `podman rmi -f`, also when it fails), but Docker's BuildKit
build cache keeps the layers of that FROM-scratch build (a few KB; `docker builder prune` would also drop the job's
other cache, so it is left) and the first rootless Podman use creates its storage under `~/.local/share/containers`.
`linux/services` stops the PostgreSQL and MySQL services it started. On a hosted runner the VM is discarded anyway;
on a candidate these are the leftovers to expect.

## Layout

| Path | Role |
|---|---|
| `invoke-workloads.sh`, `invoke_workloads.py` | entrypoint (bash wrapper, Python runner) |
| `lib.sh` | shared bash helpers: oracle lookups, facts, tool runner with normalized logs (`<work>`, `<repo>`, no ANSI) and a named cause line, report, cleanup hook |
| `wl.py` | stdlib helpers for `lib.sh`: oracle flattening, observed JSON, ELF/PE/zip/tar inspection, offline wheel builder |
| `oracle/ubuntu-24.04.json` | what a correct environment shows; every value cites its source (`inventory:`, `capture:`, `capture-list:`, `readme:`, `docs:`, `derived:`, `hosted:<run>/<file>:`, and before the first hosted run `provisional:`) and the tests check the citations |
| `defs/*.json`, `../actions/linux/defs/*.json`, `../xwin/defs/*.json` | P05 workload definitions (`fixture_id` in evidence is `workload/<id>`) |
| `tree_manifest.py` | sha256 of every file that decides a result (this tree, `../actions/linux`, `../xwin`, `certify.py`; not `oracle/hosted-runs/`, READMEs, or the oracle's `hosted_validation` key) |
| `<workload>/run.sh` + sources | one folder per workload |
| `../actions/linux/` | Actions behaviour: shell semantics, runner environment, file-command composite action |
| `../xwin/` | Linux-to-Windows cross builds and the Windows hand-off (see its README) |

Every definition runs `bash {fixtures}/../../../../parity/workloads/<path>/run.sh`: the P05 harness only offers
`{fixtures}` (its own fixture folder), so the path climbs to the repository root from there.

## Workloads and negative controls

| Workload | What it proves | Negative control (expected first error) |
|---|---|---|
| `linux/gcc`, `linux/clang` | C with libm, pthreads and OpenSSL (libssl-dev), static and shared library with `$ORIGIN` rpath, C++17; `-Wall -Werror`; run and ELF-inspected. gcc/GNU ld and clang 18/lld | sysroot without OpenSSL's headers (`fatal error: openssl/evp.h`); lld path that does not exist (`clang: error: invalid linker name`) |
| `linux/gxx14-cxx23` | g++-14 beside the default g++ builds C++23 `<print>` | the default g++ 13 (`fatal error: print: No such file or directory`) |
| `linux/cmake-ninja`, `linux/cmake-make` | CMake 3.31 configure, build, ctest, cpack TGZ read back | PATH without ninja (`CMake Error: CMake was unable to find a build program corresponding to "Ninja"`) |
| `linux/rust` | cargo test/build/run offline, build.rs compiling C with cc/ar | PATH without cc (`error: linker `cc` not found`) |
| `linux/go` | default Go, cgo module, test/build/run offline | PATH without gcc (`cgo: C compiler "gcc" not found`) |
| `linux/dotnet-net8`, `-net10` | SDK band via global.json; build, run, publish apphost, pack nupkg, no package source | net7.0, whose targeting pack is not installed (`error NU1100: Unable to resolve 'Microsoft.NETCore.App.Ref`; hosted Windows says NU1101) |
| `linux/node-addon` | Node-API addon against the installed Node headers, loaded by node | empty Node include folder (`fatal error: node_api.h`) |
| `linux/python-wheel` | CPython extension, wheel requiring a second wheel, pip `--no-index` install, import | required wheel missing from the local package folder (`ERROR: Could not find a version that satisfies the requirement aap-parity-dep`) |
| `linux/java`, `linux/java-gradle` | default JDK via JAVA_HOME (javac/jar/java), every `JAVA_HOME_<n>_X64`; Gradle `--offline` jar | JAVA_HOME unset (`JAVA_HOME is not set`); JAVA_HOME at an empty folder (Gradle's `ERROR: JAVA_HOME is set to an invalid directory`) |
| `linux/android` | SDK/NDK variables, NDK and build-tools folders, tool revisions; NDK clang arm64 build, ELF-inspected | ANDROID_NDK_HOME at a missing NDK (`NDK clang not found under ANDROID_NDK_HOME`) |
| `linux/browsers` | Chrome, ChromeDriver, Chromium, Edge, Edge WebDriver, Firefox, Geckodriver versions, driver variables, headless Chrome (default sandbox) runs a local page | CHROME_BIN at a missing file (`CHROME_BIN is not an executable`) |
| `linux/containers` | Docker/Buildx/Compose/Podman versions, cached images, FROM-scratch image built and run, bind-mounted workspace (container job), service container with alias, health check and published port (services) | DOCKER_HOST at a missing socket (`Cannot connect to the Docker daemon`) |
| `linux/services` | systemd unit states; PostgreSQL and MySQL started with `sudo systemctl start`, answering, stopped again | PostgreSQL queried without starting it (`psql: error: connection to server on socket`) |
| `linux/registry-tls` | OpenSSL package, CA bundle (system, Python, Node), apt mirrors and sources, npm/pip/NuGet registry configuration, local TLS server trusted through its CA | curl without the CA (`curl: (60) SSL certificate`) |
| `linux/toolchain-versions` | every build tool on PATH reports the inventory version | `~/.cargo/bin` off PATH (`oracle version.rustc expected '1.99.0' observed ''`) |
| `actions/linux/shell-semantics` | runner templates for bash, sh, pwsh, python and the default shell: errexit, pipefail, exit codes; resolution of each shell; the runner's own step command line | a `bash` that is really dash first on PATH (`bash on PATH is not GNU bash`) |
| `actions/linux/runner-env` | default and image variables, file-command files, PATH order, tool cache layout, action archive cache, user and groups, passwordless sudo, limits, sysctls, Docker socket | tool cache looked up in an empty folder (`oracle tool_cache.CodeQL/2.27.2 expected 'yes' observed ''`) |
| `actions/linux/file-commands` | marker from the composite action: GITHUB_ENV (incl. multiline) from bash, sh and pwsh, GITHUB_PATH, GITHUB_OUTPUT from python, step summary, working-directory | a marker that was never written (`file-commands marker not found`) |
| `xwin/clang-lld-pe` | Linux-to-Windows: clang + lld-link build a CRT-free x64 PE with an llvm-lib import library; PE-inspected; hand-off record | the import library the link names is missing (`lld-link: error: could not open 'kernel32.lib'`) |
| `xwin/sdk-cross` | Linux-to-Windows with the MSVC CRT and Windows SDK from an xwin sysroot: **unqualified on this profile** | XWIN_SYSROOT unset after proving it was set (`XWIN_SYSROOT is not set`) |

Every negative first proves its sabotage held (a `sabotage.*` fact: the header absent from the sysroot, nothing at
the lld path, ninja/cc/gcc not resolvable, the dep wheel absent, the socket absent, PostgreSQL inactive, the fake
bash on PATH, JDK 17 still installed for the Gradle negative, the .def file there for the import-library negative,
a sysroot that was really set for the xwin SDK negative), so it cannot pass because of an unrelated failure, and its
expected text is the first error line.

## Artifacts and comparison

Build workloads write `report.txt`: program output, ELF class/machine/type and DT_NEEDED, package entry lists (tgz,
nupkg, wheel, jar), PE machine/subsystem/imports. No versions, paths or times, so the report hash is the same on the
hosted reference and a correct candidate and `compare_artifacts` stays `sha256`. Report hashes are pinned in
`expected_hashes` from the hosted run. Compiled Linux binaries are inspected, not hashed; the xwin PE is hashed
(`/brepro` makes it reproducible for one lld version) because the Windows twin must run exactly those bytes.

## Validation status and gaps

- Hosted iteration 1 (run 39450814977, image 20261012.334.1, head 0af2bc2): 39/44. Classified and fixed after it:
  oracle values the baseline could not show (the default JDK reports 17.0.20.1+1 where the inventory lists
  17.0.20+1; pip's global configuration sets `break-system-packages`; through the runner's pwsh template `exit N`
  and a failing last native command end pwsh with 1, as P17 saw on Windows); one workload bug (`tls.curl` counted
  matching lines, and the s_server page names itself twice); two negative texts that are genuine hosted differences
  (.NET on Linux reports `NU1100` where hosted Windows reports `NU1101`, having no library-packs source; lld-link
  first reports the missing `kernel32.lib` the link names). Every `provisional:` value now cites that run's logs
  under `oracle/hosted-runs/39450814977/`, and every report hash is pinned from it. Negatives that lacked a proof
  fact got one (.NET: the net8.0 targeting pack present, net7.0's absent; Java: the JDK still installed with
  JAVA_HOME unset; file-commands: the real marker present).
- Hosted-validated: run 39451894408 (image 20261012.334.1, head 35baccc): 44/44, all 23 qualified positives and all
  21 qualified negatives, and its `summary.json` tree manifest equalled the tree at 35baccc; `xwin/sdk-cross` and its negative
  are listed as unqualified, not run. Every negative fails with its expected text as the first error line, its
  positive twin passed in the same run, and its observed facts show the sabotage held (a `sabotage.*` fact, or for
  `runner-env` the tool-cache variables unchanged and for `registry-tls` the TLS server reachable) and no other failed
  check except the ones the sabotage implies (every tool cache entry; rustc, cargo and rustup all live in
  `~/.cargo/bin`). `oracle/hosted-runs/39451894408/` keeps its `summary.json` and `results.json`.
- Independent review of 038b208, fixed: the three cited iteration-1 logs were ignored by `.gitignore` (`*.log`) and
  are now tracked, and the tests require every cited evidence file to be tracked; `xwin/sdk-cross.neg-no-sysroot`
  first proves a sysroot was set (`sabotage.sysroot_was_set`), so naming it on a host without one fails instead of
  passing; `handoff.py verdict` fails closed (sha256 of 64 hex digits, same artifact name, integer exit codes, string
  output); `Invoke-HandoffExecution.ps1` accepts only a plain artifact file name; the version queries, npm and
  headless Chrome keep their state in the work folder; the Gradle and import-library negatives record what they
  still have (JDK 17, the .def file); `wl_end` runs a dying `wl_cleanup` once. These change the tree, so a new hosted
  run replaces the evidence above (`check_hosted_run.py` is red until then).
- `tests/parity/workloads/linux/check_hosted_run.py` compares the tree with the run named in the oracle's
  `hosted_validation.run`: every definition hash, report hash and first error in its `results.json`, the
  unqualified list and the content manifest in its `summary.json` (added, removed or changed files are listed).
  After changing anything the manifest covers, rerun `parity-workloads.yml` and replace that evidence.
- The hosted Linux-built `parity-freestanding.exe` (sha256 e713b3b4..., byte-identical to an LLVM 22 Windows build
  of the same source thanks to `/brepro`) was run on a native Windows 11 host (the owner's, build 26300) with
  `Invoke-HandoffExecution.ps1` under Windows PowerShell 5.1: exit 42, expected output, `handoff.py verdict`
  `executed-on-windows`. The records are in `oracle/hosted-runs/39450814977/xwin/`. That host is not a hosted
  Windows runner; executing on the Windows twin in CI stays with P22/P24.
- Not covered here: Actions-managed `container:` jobs, `services:` and Docker container actions (all pull images
  from a registry; `linux/containers` covers the same Docker features without a pull), `actions/cache` and
  `upload-artifact` round trips (they need the job's runtime token and GitHub's services; `runner-env` checks the
  action archive cache they are resolved from), Maven builds, sdkmanager, setup-* actions installing uncached
  versions, and candidate execution (P22/P24).
- `xwin/sdk-cross` is unqualified on ubuntu-24.04: the inventory has no xwin and no Windows SDK or MSVC CRT, and
  P18 downloads nothing. It runs where `XWIN_SYSROOT` is provisioned.
