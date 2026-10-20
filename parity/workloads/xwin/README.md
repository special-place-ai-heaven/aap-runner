# Linux-to-Windows cross builds (P18 xwin)

Run through `parity/workloads/linux/invoke-workloads.sh` (definitions in `defs/`, script `run.sh`).

**Rule: cross compilation alone never certifies Windows execution.** A Linux build of a Windows program is evidence
that the program was *built*. Its hand-off record (`<name>.handoff.json`, written by `handoff.py built`) always says
`"windows_execution": "not-claimed"`. Execution evidence exists only when a Windows machine ran exactly those bytes:

1. The Linux run's `artifacts/<id>/` holds `<name>.exe` and `<name>.handoff.json` (both hashed in the results).
2. On Windows (the P17 twin, P22/P24 lanes): `pwsh -File parity/workloads/xwin/Invoke-HandoffExecution.ps1 -Dir <dir>`
   checks that each record names a plain file in that folder and that the file has the recorded sha256, runs it and
   writes `<name>.executed.json` (runner OS, OS version, exit code, stdout, run id). It runs what the records name:
   give it artifacts only from runs of trusted refs of this repository.
3. `python -B -I parity/workloads/xwin/handoff.py verdict <name>.handoff.json <name>.executed.json` prints
   `executed-on-windows` (exit 0) only when the record comes from Windows, names the same artifact with the same
   sha256 (64 hex digits), and the exit code (an integer) and output are the expected ones; output is compared after
   CRLF to LF and stripping surrounding whitespace. Anything missing or malformed is `built-only: <reasons>` (exit 1).
   For CI evidence (P22/P24) the executed record must also carry the hosted Windows run's `run_id`; a record without
   one (as below) is local evidence only.

| Workload | On ubuntu-24.04 |
|---|---|
| `xwin/clang-lld-pe` | qualified if the image's clang has lld-link and llvm-lib beside it: a CRT-free x64 console program (`src/freestanding.c`, kernel32 imports from `src/kernel32.def`), exit code 42, prints `hello from xwin freestanding`. Negative: the import library the link names is missing (`lld-link: error: could not open 'kernel32.lib'`). |
| `xwin/sdk-cross` | **unqualified**: needs `XWIN_SYSROOT`, an xwin splat of the MSVC CRT and Windows SDK (`crt/include`, `crt/lib/x86_64`, `sdk/include/{ucrt,um,shared}`, `sdk/lib/{ucrt,um}/x86_64`). The inventory has none and P18 downloads nothing. `src/hello.c`, exit 43. Negative: XWIN_SYSROOT unset; it first checks that a sysroot was really set, so on a host without one the negative fails too instead of passing for nothing. |

Evidence so far: the artifact of hosted run 39450814977 (sha256
`e713b3b44aa4d73ce5586feb6755f2f9f4ed6310f12740702ebb03106e41b6c7`) ran on a native Windows 11 host (the owner's,
build 26300) through `Invoke-HandoffExecution.ps1` under Windows PowerShell 5.1 (and the same bytes, rebuilt with
LLVM 22 on Windows, under pwsh 7): exit 42, expected output, verdict `executed-on-windows`. Records:
`../linux/oracle/hosted-runs/39450814977/xwin/`. Running it on the hosted Windows twin is P22/P24.
