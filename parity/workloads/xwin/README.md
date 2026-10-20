# Linux-to-Windows cross builds (P18 xwin)

Run through `parity/workloads/linux/invoke-workloads.sh` (definitions in `defs/`, script `run.sh`).

**Rule: cross compilation alone never certifies Windows execution.** A Linux build of a Windows program is evidence
that the program was *built*. Its hand-off record (`<name>.handoff.json`, written by `handoff.py built`) always says
`"windows_execution": "not-claimed"`. Execution evidence exists only when a Windows machine ran exactly those bytes:

1. The Linux run's `artifacts/<id>/` holds `<name>.exe` and `<name>.handoff.json` (both hashed in the results).
2. On Windows (the P17 twin, P22/P24 lanes): `pwsh -File parity/workloads/xwin/Invoke-HandoffExecution.ps1 -Dir <dir>`
   checks each artifact's sha256 against its hand-off record, runs it and writes `<name>.executed.json` (runner OS,
   OS version, exit code, stdout, run id).
3. `python -B -I parity/workloads/xwin/handoff.py verdict <name>.handoff.json <name>.executed.json` prints
   `executed-on-windows` (exit 0) only when the record comes from Windows, the sha256 matches and the exit code and
   output are the expected ones; anything else is `built-only: <reasons>` (exit 1).

| Workload | On ubuntu-24.04 |
|---|---|
| `xwin/clang-lld-pe` | qualified if the image's clang has lld-link and llvm-lib beside it: a CRT-free x64 console program (`src/freestanding.c`, kernel32 imports from `src/kernel32.def`), exit code 42, prints `hello from xwin freestanding`. Negative: no import library. |
| `xwin/sdk-cross` | **unqualified**: needs `XWIN_SYSROOT`, an xwin splat of the MSVC CRT and Windows SDK (`crt/include`, `crt/lib/x86_64`, `sdk/include/{ucrt,um,shared}`, `sdk/lib/{ucrt,um}/x86_64`). The inventory has none and P18 downloads nothing. `src/hello.c`, exit 43. Negative: XWIN_SYSROOT unset. |

The freestanding source was built with LLVM 22 on Windows and run through `Invoke-HandoffExecution.ps1` under pwsh 7
and Windows PowerShell 5.1 on the owner's host (exit 42, expected output, verdict `executed-on-windows`): that checks
the program and the scripts, not the Linux-to-Windows chain, which needs the hosted Linux artifact on Windows.
