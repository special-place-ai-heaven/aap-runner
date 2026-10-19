"""Print the provisioner sequence of a Packer build template as numbered Markdown.

Usage: python -I provisioning_order.py <template.pkr.hcl>
Reboot boundaries (windows-restart, `sudo reboot`) are shown as REBOOT lines.
Treat the input as untrusted data; this only reads and prints.
"""
import re
import sys

txt = open(sys.argv[1], encoding="utf-8").read()
blocks = []
for m in re.finditer(r'provisioner "([\w-]+)" \{', txt):
    i, depth = m.end(), 1
    while depth:
        c = txt[i]
        depth += (c == "{") - (c == "}")
        i += 1
    blocks.append((m.group(1), txt[m.end():i - 1]))

step = 0
for kind, body in blocks:
    scripts = re.findall(r'"\$\{path\.root\}/\.\./scripts/(?:build|tests)/([^"]+)"', body)
    script1 = re.search(r'script\s*=\s*"\$\{path\.root\}/\.\./scripts/(?:build|tests)/([^"]+)"', body)
    flags = []
    if re.search(r"elevated_user", body):
        flags.append("elevated as install user")
    if re.search(r'execution_policy\s*=\s*"(\w+)"', body):
        flags.append("execution_policy=" + re.search(r'execution_policy\s*=\s*"(\w+)"', body).group(1))
    if re.search(r"valid_exit_codes", body):
        flags.append("exit 3010 (reboot pending) accepted")
    pb = re.search(r'pause_before\s*=\s*"([^"]+)"', body)
    if pb:
        flags.append("pause_before " + pb.group(1))
    if re.search(r"skip_clean\s*=\s*true", body):
        flags.append("skip_clean")
    if kind == "windows-restart":
        t = re.search(r'restart_timeout\s*=\s*"([^"]+)"', body)
        print("- **REBOOT** (windows-restart, timeout %s%s)" % (t.group(1) if t else "default",
              ", registry check" if "check_registry" in body else ""))
        continue
    if kind == "shell" and "sudo reboot" in body:
        print("- **REBOOT** (`sudo reboot`, expect_disconnect; next step pauses 5m)")
        continue
    if kind == "file":
        continue
    names = scripts or ([script1.group(1)] if script1 else [])
    if names:
        step += 1
        extra = (" [" + "; ".join(flags) + "]") if flags else ""
        print("- Step %d (%s)%s" % (step, kind, extra))
        for n in names:
            print("  - `%s`" % n)
    elif "inline" in body:
        inl = re.findall(r'"((?:[^"\\]|\\.)*)"', body.split("inline", 1)[1].split("]", 1)[0])
        step += 1
        print("- Step %d (%s inline)%s: %s" % (step, kind, (" [" + "; ".join(flags) + "]") if flags else "",
              " | ".join(s[:90] for s in inl[:3]) + (" | ..." if len(inl) > 3 else "")))
