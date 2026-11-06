# Readme not stored

The upstream software Readme contains a default database credential. This repository does not reproduce
credential values, so the Readme is not copied here. Its content is fully recorded in `../inventory.json`
(the credential line is masked there). Retrieve the original from the pinned commit and check the hash:

- URL: https://raw.githubusercontent.com/actions/runner-images/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/Windows2025-VS2026-Readme.md
- SHA-256 at the pin: `1be74251a3224d797dd351ce4509c3576a5ad417bed3c923d05a39a5f770bad6`
- SHA-256 at release commit `aee0669dd04510a11756664eb77f5630debabed3`: the same value (byte-identical).
- Verify the inventory: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory.json`

## Refresh for the 2026-11 hosted image roll (image `win25-vs2026/20261103.298.1`)

`../inventory-20261103.298.json` is the Readme of release `win25-vs2026/20261103.298` (commit `0471fcb4ccff9a5b05d3fa2ccd932d470e3d6d38`), built with `tools/build_inventory.py` and checked with `tools/verify_inventory.py` (401 of 401 content lines covered; the credential line is masked as before). The oracle of `parity/workloads/windows` cites it, together with `hosted-capture-42235377195.log` (hosted-reference-windows-2025-vs2026 run 42235377195, image `20261103.298.1`). The frozen `../inventory.json` and the `39303666617` capture stay untouched: the image plans hash them.

- URL: https://raw.githubusercontent.com/actions/runner-images/0471fcb4ccff9a5b05d3fa2ccd932d470e3d6d38/images/windows/Windows2025-VS2026-Readme.md
- SHA-256: `f88ef1ef974d7b0e1e59f73ab5b7610ec368842835557b65316b022eaaa0e090`
- Toolset copy: `release-0471fcb/toolset-2025-vs2026.json` (hashed in `SHA256SUMS`).
- Verify: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory-20261103.298.json`
