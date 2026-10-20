# Windows and Actions compatibility workloads (P17)

Real build workloads for the `windows-2025-vs2026` profile. Each one compiles, links, runs and inspects a tiny
self-contained project the way a hosted job would, against an oracle taken from the frozen baseline
(`parity/baselines/windows-2025-vs2026-x64`). Each has a negative control: the same workload with a deliberately
missing SDK, library, environment variable or tool, which must fail with a named first error. This leaf closes on
hosted-reference oracle validation and those negative controls; running them on the local candidate VM is P22/P24.

## Run

```powershell
pwsh -NoProfile -File parity\workloads\windows\Invoke-Workloads.ps1        # all, into $env:PARITY_OUT or $env:RUNNER_TEMP\parity-out
pwsh -NoProfile -File parity\workloads\windows\Invoke-Workloads.ps1 -List
pwsh -NoProfile -File parity\workloads\windows\Invoke-Workloads.ps1 -Name windows/msvc,windows/rust-plain -OutDir C:\t\out
```

Hosted validation: `gh workflow run parity-workloads.yml --ref main -f ref=<branch> -f profile=windows-2025-vs2026
-f entry=parity/workloads/windows/Invoke-Workloads.ps1 -f args='-Name windows/msvc'`. The entrypoint runs under pwsh
or Windows PowerShell 5.1; every workload runs in `powershell.exe -ExecutionPolicy Bypass` (5.1).

`-Name` takes ids, prefixes (`windows/msvc` selects every msvc workload and its negative controls) or wildcards, as
several values or one comma-separated string. `-OutDir` must be new or empty. Exit code 0 means every selected
workload passed its oracle. The `actions/windows/file-commands` workload needs the composite action to have run
earlier in the same job:

```yaml
- uses: ./parity/workloads/actions/windows/file-commands
- run: pwsh -NoProfile -File parity\workloads\windows\Invoke-Workloads.ps1
```

Output folder:

| Path | Content |
|---|---|
| `defs/` | the selected definitions, as run |
| `results.json`, `logs/` | `tools/parity-certify` results and logs; usable as `--reference-results` for `certify.py certify` |
| `workloads/<id>.json` | per workload: definition oracle, observed facts, exit code, first error, artifacts with sha256, duration, image identity, source sha |
| `observed/` | the facts each workload checked (expected, observed, ok) |
| `artifacts/<id>/` | the hashed artifacts (`report.txt`) |
| `summary.json` | pass count and one row per workload |
| `work/` | build trees; removed after the run unless `-KeepWork` |

Workloads write only inside the output folder: TEMP/TMP, `CARGO_HOME`, `NUGET_PACKAGES`, `DOTNET_CLI_HOME` and pip
targets point into each workload's work folder. Nothing is downloaded: cargo runs `--offline`, NuGet has no package
source, pip runs `--no-index`, node-gyp and Maven/Gradle are not used. WSL is never started (a `bash` that resolves
to `System32\bash.exe` is refused, not run) and Docker is queried only inside an Actions job.

## Layout

| Path | Role |
|---|---|
| `Invoke-Workloads.ps1` | entrypoint (Windows PowerShell 5.1 compatible) |
| `Workload.psm1` | shared helpers: developer environment (vswhere + VsDevCmd), tool runner with path-normalized logs, PE/zip/MSI inspection, oracle facts, sabotage |
| `oracle/windows-2025-vs2026.json` | what a correct environment shows; every value cites its source (`inventory:`, `capture:`, `hosted:<run>/<file>:`, `readme:`, `docs:`, `derived:`) and the tests check the citations |
| `defs/*.json`, `../actions/windows/defs/*.json` | P05 workload definitions (`fixture_id` in evidence is `workload/<id>`) |
| `<workload>/run.ps1` + sources | one folder per workload |
| `../actions/windows/` | Actions behaviour: shell semantics, runner environment, file-command composite action |

Every definition runs `powershell.exe ... -File {fixtures}/../../../../parity/workloads/<path>/run.ps1`: the P05
harness only offers `{fixtures}` (its own fixture folder), so the path climbs to the repository root from there.

## Workloads and negative controls

| Workload | What it proves | Negative control (expected first error) |
|---|---|---|
| `windows/vs-devenv` | bare PATH (no `cl`, Git's `link.exe`), VS 18.10 Enterprise path/version/components via vswhere, VsDevCmd INCLUDE/LIB/SDK 10.0.26100.0/tool paths | `-winsdk=10.0.99999.0` (`Windows SDK 10.0.99999.0`) |
| `windows/msvc-x64`, `-x86`, `-arm64` | C and C++ with SDK/UCRT, `rc`, `lib`, advapi32, /MT and /MD, PDB; run (x64, x86 under WOW64) and inspect; arm64 cross-built and inspected only | INCLUDE or LIB without Windows Kits (`C1083 windows.h`, `LNK1181 advapi32.lib`) |
| `windows/msvc-toolset-14.44`, `-14.29` | side-by-side toolsets from the inventory via `-vcvars_ver` | `-vcvars_ver=14.99` (`Toolset directory ... not found`) |
| `windows/clang-cl` | LLVM clang-cl + lld-link from PATH without a developer environment | INCLUDE = empty folder (`'windows.h' file not found`) |
| `windows/cmake-ninja`, `windows/cmake-vs` | configure/build/ctest/cpack ZIP with Ninja+cl and with the VS 18 2026 generator | LIB without SDK (`LNK1104 kernel32.lib`); WindowsTargetPlatformVersion 10.0.99999.0 (`MSB8036`) |
| `windows/rust-plain`, `windows/rust-native` | cargo test/build/run offline; plain env must not use Git's `link.exe`; build.rs C via cl/lib | fake dev env leaving Git's link.exe (`linking with link.exe failed`); LIB without SDK |
| `windows/dotnet-net8`, `-net10` | SDK band via global.json; build, run, publish apphost, pack nupkg, no package source | net7.0 targeting pack (`NU1101 ... Microsoft.NETCore.App.Ref`) |
| `windows/msbuild-netfx` | VS MSBuild (vswhere) builds .NET Framework 4.7.2 | v4.0 (`MSB3644`) |
| `windows/node-addon` | Node-API addon with MSVC, loaded by node.exe | LIB without SDK |
| `windows/python-wheel` | CPython extension with MSVC, wheel, offline pip install, import | no Python libs (`LNK1104 python312.lib`) |
| `windows/java` | javac/jar/java through `JAVA_HOME` | JAVA_HOME = empty folder |
| `windows/package-wix`, `-innosetup`, `-7zip` | MSI (WiX 3, ICE validation), Inno setup.exe, 7z archive, read back | locator hidden (tool missing) |
| `windows/toolchain-versions` | resolved versions equal the inventory (LLVM, CMake, Ninja, Rust, Node/npm, Python/pip, Java, Go, pwsh, Windows PowerShell, Git, bash, WiX, Inno, 7-Zip, vswhere, .NET SDK set) | LLVM removed from PATH |
| `actions/windows/shell-semantics` | runner command templates for pwsh/powershell/cmd/bash/python, exit codes, shell resolution, `C:\shells` | Git removed from PATH: bash is the WSL launcher (`not a build shell`) |
| `actions/windows/runner-env` | CI/GITHUB_*/RUNNER_* and image variables, file-command files, tool cache `<tool>\<ver>\<arch>` + `.complete`, services, Windows-only Docker, admin, registry | empty tool cache |
| `actions/windows/file-commands` | marker from the composite action: GITHUB_ENV (incl. multiline), GITHUB_PATH, GITHUB_OUTPUT, step summary, working-directory | marker never written |

Linux containers are not assumed on hosted Windows: `runner-env` requires Docker's server OS to be `windows`.

## Artifacts and comparison

Each build workload writes `report.txt`: program output, PE machine and subsystem, required imports, version
resources, package entry lists (nupkg, wheel, jar, cpack zip, MSI properties). No versions, paths or times, so the
report hash is the same on the hosted reference and a correct candidate and `compare_artifacts` stays `sha256`
(no waivers). Every report hash is pinned in `expected_hashes` (owner's host, confirmed by hosted run 39351642738;
`file-commands` is its eight marker checks, all True). Compiled binaries are inspected, not hashed (they embed times
and paths).

Logs replace the work and repository paths with `<work>` and `<repo>`, so first causal errors compare across machines.
The log claim is each workload's own verdict line (`workload <id>: all oracle checks met` / `N oracle check(s) not met`).

## Validation status and gaps

- Hosted iteration 1 (run 39351642738, image 20261007.264.1, head c2ba84e): 39/47. Fixed after it: two oracle values
  copied wrongly from the capture (ImageOS, ImageVersion), the default JDK's version string (the inventory lists the
  tool-cache folder 17.0.20+101, the JDK reports 17.0.20.1+1), CTest 4.x's summary line, the .NET negatives' first
  error (hosted NuGet also searches `C:\Program Files\dotnet\library-packs`: NU1101), the cmake-vs negative (a
  CMAKE_SYSTEM_VERSION newer than any installed SDK only caps the selection; WindowsTargetPlatformVersion fails with
  MSB8036), and a helper bug that stopped runner-env before its checks.
- `oracle/hosted-runs/<run>/` keeps the hosted log excerpts the `hosted:` citations point at.
- Through the runner's `-command ". 'script'"` template, `exit N` (and the runner's appended `exit $LASTEXITCODE`
  after a failing native command) ends pwsh 7.6.6 and Windows PowerShell 5.1 with exit code 1, not N as GitHub's docs
  say. Observed on the hosted image and the owner's host; the oracle records 1.
- Not covered here: node-gyp (downloads Node headers), Maven/Gradle builds (download plugins), setup-* actions
  installing uncached versions, cache/artifact actions and network acquisition (P03/P18/P22), the default `shell:`
  when a step names none, Windows service workloads beyond state checks, and candidate execution (P22/P24).
