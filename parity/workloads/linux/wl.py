"""Helpers for lib.sh (stdlib only; run as python3 -B -I wl.py <command> ...).

  flat ORACLE.json                       oracle as '<key>\t<value>' lines: a cited value {v, src} at key a/b, a list as
                                         one 'a/b[]' line per element, null as an empty value
  observed FACTS.tsv OUT.json ID PROFILE SABOTAGE WORK FAILURES
                                         facts lines '<name>\t<ok>\t<expected>\t<observed>' (ok '' = observation only)
  zip ARCHIVE | tar ARCHIVE              sorted entry names
  elf FILE                               class, machine, type and sorted DT_NEEDED names of an ELF file
  pe FILE                                machine, subsystem, dll flag and sorted imported DLL names of a PE file
  wheel EXT_SO OUTDIR NAME DEPENDS       a wheel for one extension module (fixed timestamps, sorted entries)
"""
import base64
import hashlib
import json
import os
import struct
import sys
import sysconfig
import tarfile
import zipfile


def flat(path):
    def walk(o, key):
        if isinstance(o, dict) and "src" in o:
            v = o["v"]
            for x in v if isinstance(v, list) else [v]:
                if isinstance(x, dict):
                    for k, y in x.items():
                        print(f"{key}/{k}\t{'' if y is None else y}")
                else:
                    print(f"{key}{'[]' if isinstance(v, list) else ''}\t{'' if x is None else x}")
        elif isinstance(o, dict):
            for k, v in o.items():
                walk(v, f"{key}/{k}" if key else k)

    with open(path, encoding="utf-8") as f:
        walk(json.load(f), "")


def observed(facts, out, wid, profile, sabotage, work, failures):
    rows = {}
    with open(facts, encoding="utf-8") as f:
        for line in f.read().splitlines():
            name, ok, exp, obs = (line.split("\t") + ["", "", ""])[:4]
            rows[name] = {"observed": obs} if ok == "" else {"observed": obs, "expected": exp, "ok": ok == "1"}
    doc = {"id": wid, "profile": profile, "sabotage": sabotage, "work": work,
           "failures": [x for x in failures.split("\n") if x], "facts": rows}
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")


def elf(path):
    with open(path, "rb") as f:
        b = f.read()
    if b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1:
        sys.exit(f"error: not a little-endian ELF64 file: {path}")
    etype, machine = struct.unpack_from("<HH", b, 16)
    shoff, = struct.unpack_from("<Q", b, 40)
    shentsize, shnum = struct.unpack_from("<HH", b, 58)
    secs = [struct.unpack_from("<IIQQQQIIQQ", b, shoff + i * shentsize) for i in range(shnum)]
    needed = []
    for s in secs:
        if s[1] == 6:  # SHT_DYNAMIC; its sh_link is the string table
            strtab = secs[s[6]][4]
            for off in range(s[4], s[4] + s[5], 16):
                tag, val = struct.unpack_from("<qQ", b, off)
                if tag == 0:
                    break
                if tag == 1:  # DT_NEEDED
                    needed.append(b[strtab + val:b.index(b"\0", strtab + val)].decode())
    machines = {62: "x86-64", 183: "aarch64", 3: "x86", 40: "arm"}
    types = {1: "rel", 2: "exec", 3: "dyn"}
    print(f"class=elf64 machine={machines.get(machine, machine)} type={types.get(etype, etype)}")
    for n in sorted(needed):
        print(f"needed={n}")


def pe(path):
    with open(path, "rb") as f:
        b = f.read()
    if b[:2] != b"MZ":
        sys.exit(f"error: not a PE file: {path}")
    p, = struct.unpack_from("<I", b, 0x3C)
    machine, nsec = struct.unpack_from("<HH", b, p + 4)
    optsize, chars = struct.unpack_from("<HH", b, p + 20)
    opt = p + 24
    magic, = struct.unpack_from("<H", b, opt)
    subsys, = struct.unpack_from("<H", b, opt + 68)
    ddir = opt + (112 if magic == 0x20B else 96)
    imp_rva, imp_size = struct.unpack_from("<II", b, ddir + 8)
    secs = [struct.unpack_from("<8sIIII", b, opt + optsize + 40 * i) for i in range(nsec)]

    def off(rva):
        for _, vsize, va, rawsize, raw in secs:
            if va <= rva < va + max(vsize, rawsize):
                return rva - va + raw
        raise ValueError(f"rva {rva:#x} outside every section")

    dlls = []
    if imp_size:
        d = off(imp_rva)
        while True:
            name_rva, = struct.unpack_from("<I", b, d + 12)
            if not name_rva:
                break
            o = off(name_rva)
            dlls.append(b[o:b.index(b"\0", o)].decode().lower())
            d += 20
    machines = {0x8664: "x64", 0x14C: "x86", 0xAA64: "arm64"}
    print(f"machine={machines.get(machine, hex(machine))} subsystem={ {2: 'gui', 3: 'console'}.get(subsys, subsys)} dll={bool(chars & 0x2000)}")
    for n in sorted(dlls):
        print(f"import={n}")


def wheel(ext, out, name, depends):
    tag = f"cp{sys.version_info[0]}{sys.version_info[1]}"
    tag = f"{tag}-{tag}-{sysconfig.get_platform().replace('-', '_').replace('.', '_')}"
    di = f"{name}-1.0.0.dist-info"
    meta = f"Metadata-Version: 2.1\nName: {name.replace('_', '-')}\nVersion: 1.0.0\n"
    meta += "".join(f"Requires-Dist: {d}\n" for d in depends.split(",") if d)
    files = {f"{di}/METADATA": meta.encode(),
             f"{di}/WHEEL": f"Wheel-Version: 1.0\nGenerator: aap-parity\nRoot-Is-Purelib: {'false' if ext != '-' else 'true'}\nTag: {tag if ext != '-' else 'py3-none-any'}\n".encode()}
    if ext != "-":
        with open(ext, "rb") as f:
            files[os.path.basename(ext)] = f.read()
    else:
        files[f"{name}.py"] = b"VALUE = 'dep-ok'\n"
    record = "".join(f"{n},sha256={base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b'=').decode()},{len(b)}\n"
                     for n, b in sorted(files.items()))
    files[f"{di}/RECORD"] = (record + f"{di}/RECORD,,\n").encode()
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"{name}-1.0.0-{tag if ext != '-' else 'py3-none-any'}.whl")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n in sorted(files):
            z.writestr(zipfile.ZipInfo(n, (1980, 1, 1, 0, 0, 0)), files[n])
    print(path)


def main(a):
    if a[0] == "flat":
        flat(a[1])
    elif a[0] == "observed":
        observed(*a[1:8])
    elif a[0] == "zip":
        print("\n".join(sorted(zipfile.ZipFile(a[1]).namelist())))
    elif a[0] == "tar":
        with tarfile.open(a[1]) as t:
            print("\n".join(sorted(m.name + ("/" if m.isdir() else "") for m in t.getmembers())))
    elif a[0] == "elf":
        elf(a[1])
    elif a[0] == "pe":
        pe(a[1])
    elif a[0] == "wheel":
        wheel(*a[1:5])
    else:
        sys.exit(f"error: unknown wl.py command {a[0]}")


if __name__ == "__main__":
    main(sys.argv[1:])
