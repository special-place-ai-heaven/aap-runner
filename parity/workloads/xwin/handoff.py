"""Hand-off records for Linux-to-Windows cross builds (stdlib only).

  handoff.py built ARTIFACT EXPECTED_EXIT EXPECTED_STDOUT OUT.json   record a cross-built artifact (Linux side)
  handoff.py verdict BUILT.json [EXECUTED.json]                       'executed-on-windows' (exit 0) or
                                                                      'built-only: <reasons>' (exit 1)

The rule: a cross build is evidence that an artifact was built, never that it runs on Windows. A built record always
says windows_execution 'not-claimed'. Only an executed record written on Windows by Invoke-HandoffExecution.ps1
(runner_os Windows, the same artifact name and sha256, the expected integer exit code and output) turns it into
executed-on-windows evidence; any missing or malformed field means built-only.
"""
import hashlib
import json
import os
import platform
import re
import sys

SHA = re.compile(r"^[0-9a-f]{64}$")


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def built(artifact, exit_code, stdout, out):
    rec = {"schema": 1, "kind": "xwin-built", "artifact": os.path.basename(artifact), "sha256": sha256(artifact),
           "expected_exit": int(exit_code), "expected_stdout": stdout,
           "built_on": platform.system(), "windows_execution": "not-claimed"}
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(rec, f, indent=1)
        f.write("\n")


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def verdict(b, e):
    """Fails closed: every field it compares must be present and well typed. Output is compared after CRLF -> LF and
    stripping leading and trailing whitespace (the program's trailing newline)."""
    why = []
    if b.get("kind") != "xwin-built" or b.get("windows_execution") != "not-claimed":
        why.append("the built record is not a plain xwin-built record")
    if not (isinstance(b.get("sha256"), str) and SHA.match(b["sha256"])):
        why.append("the built record has no sha256")
    if not (isinstance(b.get("artifact"), str) and b["artifact"]):
        why.append("the built record names no artifact")
    if not _int(b.get("expected_exit")) or not isinstance(b.get("expected_stdout"), str):
        why.append("the built record's expected exit code or output is malformed")
    if e is None:
        why.append("no Windows execution record")
    else:
        if e.get("kind") != "xwin-executed" or e.get("runner_os") != "Windows":
            why.append(f"execution record is not from Windows (runner_os {e.get('runner_os')!r})")
        if e.get("artifact") != b.get("artifact"):
            why.append(f"executed artifact {e.get('artifact')!r} is not the built one {b.get('artifact')!r}")
        if e.get("sha256") != b.get("sha256"):
            why.append("executed artifact differs from the built one (sha256)")
        if not _int(e.get("exit_code")) or e.get("exit_code") != b.get("expected_exit"):
            why.append(f"exit code {e.get('exit_code')!r} != expected {b.get('expected_exit')!r}")
        out = e.get("stdout")
        if not isinstance(out, str) or out.replace("\r\n", "\n").strip() != b.get("expected_stdout"):
            why.append(f"output {out!r} != expected {b.get('expected_stdout')!r}")
    return "executed-on-windows" if not why else "built-only: " + "; ".join(why)


def load(path):
    with open(path, encoding="utf-8-sig") as f:  # Windows PowerShell 5.1 may write a BOM
        return json.load(f)


def main(a):
    if a[0] == "built" and len(a) == 5:
        built(*a[1:])
        return 0
    if a[0] == "verdict" and len(a) in (2, 3):
        v = verdict(load(a[1]), load(a[2]) if len(a) == 3 else None)
        print(v)
        return 0 if v == "executed-on-windows" else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
