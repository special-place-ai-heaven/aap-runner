# zccache 1.15.11 release artifacts for qualification

Pin: tag `1.15.11`, commit `e5bc38be49dbd88963167e343256b31cca8c1678`. Archive sizes and digests
are the published values recorded in [parity/baselines/zccache.md](../../baselines/zccache.md)
(release API `digest`, cross-checked against `SHA256SUMS` and `manifest.json`).

## Assets per platform

| Platform | Archive | Bytes | Archive SHA-256 |
|---|---|---:|---|
| Linux x86_64 (musl) | `zccache-v1.15.11-x86_64-unknown-linux-musl.tar.gz` | 12330509 | `b79cac8a521056ef66de3f903546648f21a6da3d3880af33463f66200143949b` |
| Windows x86_64 | `zccache-v1.15.11-x86_64-pc-windows-msvc.zip` | 10443043 | `4b33feb8da02f2564a1f5c9846d03a7a5af8ab0ab2f2b10560a11f30e5bbef81` |

Download URL: `https://github.com/forge-ci/zccache/releases/download/1.15.11/<archive>`. The
`-debug` archives are not used.

## Archive members (checked 2026-11-01)

On 2026-11-01 both archives were downloaded outside the repository. Both hashed to the digests
above. They were unpacked in a scratch directory and the members were hashed. Nothing was executed.
The `zccache` hashes fill `binary_sha256` in the two matrices. The harnesses pin both `zccache`
and its sibling `zccache-fp`, and refuse to run (exit 4) if either differs.

| Archive | Member | Bytes | SHA-256 |
|---|---|---:|---|
| Linux musl | `zccache-v1.15.11-x86_64-unknown-linux-musl/zccache` (mode 0755) | 27744784 | `fd9fc89ee8273a03f7dabce8459abf41ddf5ab8a27cd9db552384ac9a77af980` |
| Linux musl | `zccache-v1.15.11-x86_64-unknown-linux-musl/zccache-fp` (mode 0755) | 5010776 | `e57cdc72f35b9b597ea24fcfd2859126eac8654c6291a72cc10995e5bf8e962b` |
| Linux musl | `zccache-v1.15.11-x86_64-unknown-linux-musl/README.md` | 71980 | `6d8450dc07e621383da62a9aef854d7c1bc9d1e66d55415c77dddd786746bb71` |
| Windows | `zccache-v1.15.11-x86_64-pc-windows-msvc/zccache.exe` | 23944832 | `4b5dc2468efeca37604b6bb25c07e7fc3d5585b30ebd6217efd56b633baa86da` |
| Windows | `zccache-v1.15.11-x86_64-pc-windows-msvc/zccache-fp.exe` | 4047488 | `6ee0ed900b9d6195f22e2ed233b0c6f7821199e07d0ec78876673182db982025` |
| Windows | `zccache-v1.15.11-x86_64-pc-windows-msvc/README.md` | 71980 | `6d8450dc07e621383da62a9aef854d7c1bc9d1e66d55415c77dddd786746bb71` |

The bundled `README.md` is byte-identical to `README.md` at the pinned commit (same SHA-256), so
the README line numbers cited across this directory apply to the shipped copy too.

The 1.15.6 Linux member matched the owner's benchmark binary (`f97ae874...cb18cc`, 27,876,808
bytes) recorded in `docs/parity/PLAN.md`. The 1.15.11 member is a different file. The benchmark
directory was not opened, moved or modified.

## Verification steps (lab, every use)

1. Download the archive by its exact name from the pinned release URL. Do not use `install.sh`,
   `install.ps1`, `releases/latest`, PyPI wheels or crates.io builds.
2. Check the archive's size and SHA-256 against the table above before it touches any other tool.
   A mismatch stops the run. The checksum file, the manifest and the API digest all come from the
   same release, so they prove transport integrity only. The release has no signature or
   provenance attestation asset, so there is no signature to verify. Skip the first line of
   `SHA256SUMS`, which hashes the file itself as the empty string (see zccache.md).
3. Unpack into a fresh directory inside the lab VM. Reject members with absolute paths, `..`
   segments or links. Hash the binary and compare it with the member table. The harnesses copy
   `zccache` and `zccache-fp` into a private directory, check the copies again and run only them.
   They exit 4 on a mismatch.
4. Execute only inside the authorized lab VM (gate D2), never on the owner's host or the live
   distro. The harnesses refuse to run without `AAP_ZCCACHE_LAB=1`, when live-install markers
   are present, or when a variable name or value in the environment looks like a credential.

## Forbidden install and restore paths

These never supply a qualification binary or cache content:

- `install.sh`, `install.ps1`, `releases/latest`, PyPI wheels and crates.io builds. They are not
  the pinned archive.
- The upstream GitHub Action `forge-ci/zccache` at any ref, including `@main`. That covers its
  compilation-cache and target-snapshot restores through the GitHub Actions cache, and its
  `zccache warm` backfill.

Upstream says plainly that warmed artifacts are trusted rather than verified (README 1070). It
also says that `zccache warm` does not checksum every restored object and that the action "does
not try to prove cache integrity before building" (README 1123, both at the pinned commit). A
restored cache is foreign content written by another job, so it falls under the trust rules in
[retention.md](retention.md). A floating `@main` ref is not pinned at all. Product jobs reach
zccache only through the P13 guest integration.

## The owner's benchmark binary is not qualification evidence

`C:\temp\aap-cache-benchmark-2026-10-18` stays untouched. Its binary matches the release member
by hash, which proves only provenance. Benchmark runs on the owner's machine are not
qualification evidence for any matrix row. They did not run the harness and did not check
uncached, cold and warm equivalence, error cases or poisoning. Qualification evidence is a
harness record produced in the lab from an archive verified as above.
