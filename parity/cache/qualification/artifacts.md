# zccache 1.15.6 release artifacts for qualification

Pin: tag `1.15.6`, commit `15ec9537af0d219e07b72ce2b3f97d5f68d72b5e`. Archive sizes and digests
are the published values recorded in [parity/baselines/zccache.md](../../baselines/zccache.md)
(release API `digest`, cross-checked against `SHA256SUMS` and `manifest.json`).

## Assets per platform

| Platform | Archive | Bytes | Archive SHA-256 |
|---|---|---:|---|
| Linux x86_64 (musl) | `zccache-v1.15.6-x86_64-unknown-linux-musl.tar.gz` | 12389072 | `885a109c758808480ebda6b92ac0c55ae55ff2638f0ef850423bb185f28e59f7` |
| Windows x86_64 | `zccache-v1.15.6-x86_64-pc-windows-msvc.zip` | 10545387 | `a9e2b079946d00757a56fea3dacd8a47f9cb4bcbfe8c427ffd719ced59fd949b` |

Download URL: `https://github.com/zackees/zccache/releases/download/1.15.6/<archive>`. The
`-debug` archives are not used.

## Archive members (P04 static check, 2026-10-19)

On 2026-10-19 P04 downloaded both archives into a scratch directory outside the repository. Both
hashed to the digests above. P04 then read the members in memory with Python's `tarfile` and
`zipfile`. Nothing was extracted to disk or executed. These values fill `binary_sha256` in the
two matrices and are pinned in the harnesses.

| Archive | Member | Bytes | SHA-256 |
|---|---|---:|---|
| Linux musl | `zccache-v1.15.6-x86_64-unknown-linux-musl/zccache` (mode 0755) | 27876808 | `f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc` |
| Linux musl | `zccache-v1.15.6-x86_64-unknown-linux-musl/zccache-fp` (mode 0755) | 4881816 | `df637b927954093a6fd5c7cc34afc3dd9470a855ec3e03e0342ee9ea9e49f058` |
| Linux musl | `zccache-v1.15.6-x86_64-unknown-linux-musl/README.md` | 71980 | `6d8450dc07e621383da62a9aef854d7c1bc9d1e66d55415c77dddd786746bb71` |
| Windows | `zccache-v1.15.6-x86_64-pc-windows-msvc/zccache.exe` | 24359040 | `41de068f3024a1bcbfea8ad488455c648ee07903e09e9fca4d663436789d0731` |
| Windows | `zccache-v1.15.6-x86_64-pc-windows-msvc/zccache-fp.exe` | 3931776 | `4c0892e47244fdc38a6542ed3b05d2d9f26d312bce505984e6a9f6766c66c987` |
| Windows | `zccache-v1.15.6-x86_64-pc-windows-msvc/README.md` | 71980 | `6d8450dc07e621383da62a9aef854d7c1bc9d1e66d55415c77dddd786746bb71` |

The bundled `README.md` is byte-identical to `README.md` at the pinned commit (same SHA-256), so
the README line numbers cited across this directory apply to the shipped copy too.

The Linux `zccache` member hashes to the same value the plan records for the owner's benchmark
binary (`f97ae874...cb18cc`, 27,876,808 bytes). The comparison used the hash in
`docs/parity/PLAN.md`. The owner's benchmark directory was not opened, moved or modified.

## Verification steps (lab, every use)

1. Download the archive by its exact name from the pinned release URL. Do not use `install.sh`,
   `install.ps1`, `releases/latest`, PyPI wheels or crates.io builds.
2. Check the archive's size and SHA-256 against the table above before it touches any other tool.
   A mismatch stops the run. The checksum file, the manifest and the API digest all come from the
   same release, so they prove transport integrity only. The release has no signature or
   provenance attestation asset, so there is no signature to verify. Skip the first line of
   `SHA256SUMS`, which hashes the file itself as the empty string (see zccache.md).
3. Unpack into a fresh directory inside the lab VM. Reject members with absolute paths, `..`
   segments or links. Hash the binary and compare it with the member table. The harnesses repeat
   this check and exit 4 on a mismatch.
4. Execute only inside the authorized lab VM (gate D2), never on the owner's host or the live
   distro. The harnesses refuse to run without `AAP_ZCCACHE_LAB=1` or when live-install markers
   are present.

## The owner's benchmark binary is not qualification evidence

`C:\temp\aap-cache-benchmark-2026-10-18` stays untouched. Its binary matches the release member
by hash, which proves only provenance. Benchmark runs on the owner's machine are not
qualification evidence for any matrix row. They did not run the harness and did not check
uncached, cold and warm equivalence, error cases or poisoning. Qualification evidence is a
harness record produced in the lab from an archive verified as above.
