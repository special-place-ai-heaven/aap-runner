# Readme not stored

The upstream software Readme contains a default database credential. This repository does not reproduce
credential values, so the Readme is not copied here. Its content is fully recorded in `../inventory.json`
(the credential line is masked there). Retrieve the original from the pinned commit and check the hash:

- URL: https://raw.githubusercontent.com/actions/runner-images/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/windows/Windows2025-VS2026-Readme.md
- SHA-256 at the pin: `1be74251a3224d797dd351ce4509c3576a5ad417bed3c923d05a39a5f770bad6`
- SHA-256 at release commit `aee0669dd04510a11756664eb77f5630debabed3`: the same value (byte-identical).
- Verify the inventory: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory.json`
