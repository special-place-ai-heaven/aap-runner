# Readme not stored

The upstream software Readme contains a default database credential. This repository does not reproduce
credential values, so the Readme is not copied here. Its content is fully recorded in `../inventory.json`
(the credential line is masked there). Retrieve the original from the pinned commit and check the hash:

- URL: https://raw.githubusercontent.com/actions/runner-images/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md
- SHA-256 at the pin: `3911b4bc1aa423be7b7469a75f3093f51306c02f2638f2a8b4f5ed31f3ffe791`
- SHA-256 at release commit `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe`: the same value (byte-identical).
- Verify the inventory: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory.json`

## Refresh for the 2026-11 hosted image roll (image `ubuntu24/20261101.360.1`)

`../inventory-20261101.360.json` is the Readme of release `ubuntu24/20261101.360` (commit `add4380b0d6685806e9192c33c37359ee0aa4023`), built with `tools/build_inventory.py` and checked with `tools/verify_inventory.py` (255 of 255 content lines covered). The oracle of `parity/workloads/linux` cites it, together with `hosted-capture-42235370098.log` (hosted-reference-ubuntu-24.04 run 42235370098, image `20261101.360.1`). The frozen `../inventory.json` and the `39305649952` capture stay untouched: the image plans hash them.

- URL: https://raw.githubusercontent.com/actions/runner-images/add4380b0d6685806e9192c33c37359ee0aa4023/images/ubuntu/Ubuntu2404-Readme.md
- SHA-256: `5993072a61c810a3bf5057bba6322e576a5d83307b87afc1c8600e05b811b124`
- Toolset copy: `release-add4380/toolset-2404.json` (hashed in `SHA256SUMS`).
- Verify: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory-20261101.360.json`
