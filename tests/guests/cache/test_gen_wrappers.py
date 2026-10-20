"""P13 qualified-wrapper manifest generator (guests/cache/gen_wrappers.py). Standard library only.

Run: python -B -I -m unittest discover -s tests/guests/cache -p "test_*.py"
AAP_ZC_SRC points the tests at another copy of guests/cache (tests/guests/cache/mutate.py uses it).
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = Path(os.environ.get("AAP_ZC_SRC") or REPO / "guests" / "cache")
QUAL = REPO / "parity" / "cache" / "qualification"
ACQUIRE = REPO / "images" / "common" / "artifacts.manifest.json"
VALIDATE = REPO / "parity" / "contracts" / "validate.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_wrappers", SRC / "gen_wrappers.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GEN = load_generator()


class Fixture:
    """A scratch repository holding copies of both matrices and the P03 manifest."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="p13-gen-"))
        self.qual = self.root / "parity" / "cache" / "qualification"
        self.qual.mkdir(parents=True)
        for p in ("linux-x86_64", "windows-x86_64"):
            shutil.copy(QUAL / f"{p}.json", self.qual / f"{p}.json")
        self.acquire = self.root / "artifacts.manifest.json"
        shutil.copy(ACQUIRE, self.acquire)

    def edit(self, path, fn):
        doc = json.loads(path.read_text(encoding="utf-8"))
        fn(doc)
        path.write_text(json.dumps(doc, indent=2), encoding="utf-8")

    def build(self):
        return GEN.build(qual_dir=self.qual, acquire=self.acquire, validate=VALIDATE, repo=self.root)

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class GenWrappers(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()

    def tearDown(self):
        self.fx.close()

    def test_committed_manifest_is_current(self):
        r = subprocess.run([sys.executable, "-B", "-I", str(REPO / "guests" / "cache" / "gen_wrappers.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_nothing_is_qualified_at_the_pin(self):
        doc = json.loads((REPO / "guests" / "cache" / "wrappers.json").read_text(encoding="utf-8"))
        for p in ("linux-x86_64", "windows-x86_64"):
            self.assertEqual(doc["platforms"][p]["qualified"], [], p)

    def test_member_pins_are_the_published_ones(self):
        text = (QUAL / "artifacts.md").read_text(encoding="utf-8")
        for p, pins in GEN.PLATFORMS.items():
            for m in pins["members"]:
                self.assertIn(m["sha256"], text, m["path"])
                self.assertIn(m["path"], text)

    def test_a_qualified_row_with_evidence_is_listed(self):
        ref = "parity/cache/qualification/evidence/linux-x86_64/clang-18.1.3-compile-object.json"

        def qualify(doc):
            for row in doc["rows"]:
                if (row["compiler"], row["compiler_version"], row["invocation"]) == ("clang", "18.1.3", "compile-object"):
                    row["mode"] = "qualified"
                    row["evidence_ref"] = ref
        self.fx.edit(self.fx.qual / "linux-x86_64.json", qualify)
        (self.fx.root / ref).parent.mkdir(parents=True)
        (self.fx.root / ref).write_text("{}", encoding="utf-8")
        doc = self.fx.build()
        self.assertEqual(doc["platforms"]["linux-x86_64"]["qualified"],
                         [{"compiler": "clang", "compiler_version": "18.1.3", "invocation": "compile-object", "evidence_ref": ref}])
        self.assertEqual(doc["platforms"]["windows-x86_64"]["qualified"], [])

    def test_refuses_a_qualified_row_without_committed_evidence(self):  # covers GEN-EVIDENCE
        def qualify(doc):
            doc["rows"][0]["mode"] = "qualified"
        self.fx.edit(self.fx.qual / "windows-x86_64.json", qualify)
        with self.assertRaisesRegex(GEN.Refused, "no committed evidence"):
            self.fx.build()

    def test_refuses_a_matrix_that_fails_validation(self):  # covers GEN-VALIDATE
        def sccache(doc):
            doc["rows"][0]["reason"] = "falls back to sccache"
        self.fx.edit(self.fx.qual / "linux-x86_64.json", sccache)
        with self.assertRaisesRegex(GEN.Refused, "fails validate.py"):
            self.fx.build()

    def test_refuses_a_binary_hash_that_is_not_the_pinned_member(self):  # covers GEN-BINARY-PIN
        def other(doc):
            doc["zccache"]["binary_sha256"] = "0" * 64
        self.fx.edit(self.fx.qual / "windows-x86_64.json", other)
        with self.assertRaisesRegex(GEN.Refused, "binary_sha256 differs"):
            self.fx.build()

    def test_refuses_when_p03_does_not_pin_the_same_archive(self):  # covers GEN-ACQUIRE
        def other(doc):
            for e in doc["entries"]:
                if e["name"] == "zccache-x86_64-unknown-linux-musl":
                    e["size_bytes"] = e["size_bytes"] + 1
        self.fx.edit(self.fx.acquire, other)
        with self.assertRaisesRegex(GEN.Refused, "does not pin the same archive"):
            self.fx.build()

    def test_lists_only_pinned_identity_fields(self):
        doc = self.fx.build()
        for p, plat in doc["platforms"].items():
            self.assertEqual(plat["members"][0]["name"].split(".")[0], "zccache", p)
            self.assertEqual(plat["archive"], GEN.load(self.fx.qual / f"{p}.json")["zccache"]["archive"])


if __name__ == "__main__":
    unittest.main()
