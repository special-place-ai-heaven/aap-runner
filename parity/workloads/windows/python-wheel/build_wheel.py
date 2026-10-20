"""Offline wheel builder for the parity_ext fixture (stdlib only; setuptools would need a download in an isolated build).

  build_wheel.py info              -> include dir, libs dir, extension suffix of this interpreter
  build_wheel.py wheel PYD OUTDIR  -> OUTDIR/aap_parity_ext-1.0.0-<tag>.whl (fixed timestamps, sorted entries)
"""
import base64
import hashlib
import os
import sys
import sysconfig
import zipfile

NAME, VERSION = "aap_parity_ext", "1.0.0"


def tag():
    v = f"cp{sys.version_info[0]}{sys.version_info[1]}"
    return f"{v}-{v}-{sysconfig.get_platform().replace('-', '_').replace('.', '_')}"


def wheel(pyd, out):
    di = f"{NAME}-{VERSION}.dist-info"
    files = {
        os.path.basename(pyd): open(pyd, "rb").read(),
        f"{di}/METADATA": f"Metadata-Version: 2.1\nName: aap-parity-ext\nVersion: {VERSION}\n".encode(),
        f"{di}/WHEEL": f"Wheel-Version: 1.0\nGenerator: aap-parity\nRoot-Is-Purelib: false\nTag: {tag()}\n".encode(),
    }
    record = "".join(
        f"{n},sha256={base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b'=').decode()},{len(b)}\n" for n, b in sorted(files.items()))
    files[f"{di}/RECORD"] = (record + f"{di}/RECORD,,\n").encode()
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"{NAME}-{VERSION}-{tag()}.whl")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n in sorted(files):
            z.writestr(zipfile.ZipInfo(n, (1980, 1, 1, 0, 0, 0)), files[n])
    print(path)


if __name__ == "__main__":
    if sys.argv[1] == "info":
        print(sysconfig.get_paths()["include"])
        print(os.path.join(sys.base_prefix, "libs"))
        print(sysconfig.get_config_var("EXT_SUFFIX"))
    else:
        wheel(sys.argv[2], sys.argv[3])
