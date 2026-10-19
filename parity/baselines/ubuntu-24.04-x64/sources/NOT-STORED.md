# Readme not stored

The upstream software Readme contains a default database credential. This repository does not reproduce
credential values, so the Readme is not copied here. Its content is fully recorded in `../inventory.json`
(the credential line is masked there). Retrieve the original from the pinned commit and check the hash:

- URL: https://raw.githubusercontent.com/actions/runner-images/ee1ff4569e381a9649b400338bdc8ceb7e18a80e/images/ubuntu/Ubuntu2404-Readme.md
- SHA-256 at the pin: `3911b4bc1aa423be7b7469a75f3093f51306c02f2638f2a8b4f5ed31f3ffe791`
- SHA-256 at release commit `7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe`: the same value (byte-identical).
- Verify the inventory: `python -I ../../tools/verify_inventory.py <downloaded Readme> ../inventory.json`
