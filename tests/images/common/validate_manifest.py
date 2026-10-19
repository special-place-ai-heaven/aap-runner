"""Check a P03 manifest against its schema with the P02 contract validator. Run with `python -I`.

    python -I validate_manifest.py <validate.py> <schema.json> <manifest.json>

Reuses check() and lint_schema() from parity/contracts/validate.py, so the manifest schema can only
use keywords that validator implements and every number in it has a maximum. Exit 0 when valid.
"""
import importlib.util
import json
import sys


def main():
    sys.dont_write_bytecode = True  # do not litter parity/contracts with __pycache__
    validator, schema_path, manifest_path = sys.argv[1:4]
    spec = importlib.util.spec_from_file_location("contract_validate", validator)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    with open(schema_path, encoding="utf-8") as f:
        schema = json.load(f)
    with open(manifest_path, encoding="utf-8") as f:
        doc = json.load(f)
    problems = mod.lint_schema(schema)
    try:
        mod.check(schema, doc, schema)
        mod._no_secret_values(doc)
    except mod.Invalid as e:
        problems.append(str(e))
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
