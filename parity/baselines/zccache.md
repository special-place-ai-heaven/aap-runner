# zccache 1.15.11 pin

Pinned release is `forge-ci/zccache` 1.15.11 (not `zackees/zccache`). Checked 2026-11-01.
`SHA256SUMS`, `manifest.json`, and the four archives this repository pins were downloaded and
hashed. The two non-debug archives were unpacked in a scratch directory and their members hashed.
They were not executed. `install.sh` and `install.ps1` were not downloaded; the hashes below are
the lines in the downloaded `SHA256SUMS`, and those lines match the release API digests. The
owner's benchmark directory was not touched.

## Identity

| Item | Value | Source |
|---|---|---|
| Repository | `forge-ci/zccache` | Z1 |
| Git tag | `1.15.11` (no `v` prefix) | Z1 |
| Tag resolves to commit | `e5bc38be49dbd88963167e343256b31cca8c1678` (a commit object, not an annotated tag) | Z2 |
| Commit date and subject | 2026-10-31T10:19:06Z, `Merge pull request #2031 from forge-ci/chore/release-1.15.11` | Z3 |
| Release `zccache 1.15.11` | published 2026-10-31T10:56:41Z, not draft, not prerelease, `target_commitish` is `main` | Z4 |
| Previous pin | `zackees/zccache` 1.15.6, commit `15ec9537af0d219e07b72ce2b3f97d5f68d72b5e` | this file, before this pin |

## Release assets

Sizes and SHA-256 values below are the SHA-256 of the downloaded bytes. They match the release
API `digest` field, the published `SHA256SUMS` lines (skipping that file's first line), and
`manifest.json` for the six release archives. Download URL pattern: `https://github.com/forge-ci/zccache/releases/download/1.15.11/<asset>`.

### Linux x86_64 musl and Windows x86_64 (the two target families)

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `zccache-v1.15.11-x86_64-unknown-linux-musl.tar.gz` | 12330509 | `b79cac8a521056ef66de3f903546648f21a6da3d3880af33463f66200143949b` |
| `zccache-v1.15.11-x86_64-unknown-linux-musl-debug.tar.gz` | 29899750 | `58db574afb2c2ad261a8ff35b5e96368ac7143dc587c555e13eb1e4ac4675909` |
| `zccache-v1.15.11-x86_64-pc-windows-msvc.zip` | 10443043 | `4b33feb8da02f2564a1f5c9846d03a7a5af8ab0ab2f2b10560a11f30e5bbef81` |
| `zccache-v1.15.11-x86_64-pc-windows-msvc-debug.zip` | 34956910 | `f354e89622fbf40fb2fd0fccb6016dbadbf0fbcd05a101d69f048d076042b1dd` |

### Release support files

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `SHA256SUMS` | 1648 | `98501a80bb111e932a8eb843d56520aa97308b465cb02b18c8eb279698352864` |
| `manifest.json` | 2032 | `c632df4cac59a1ab661766d676156d95304ac123243af110cf2b6b0eb45bcb16` |
| `install.sh` | 6470 | `31a62a81f95f83ae4eba8abde6cf14e843eb71c1e569018f24533102dc1ad95a` |
| `install.ps1` | 5462 | `56bfe5ed3841f97873439a8f5b504c6904ccd4e61854bc89fe9ee3f09137748d` |

### Other targets published (names only, out of scope for these profiles)

`aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-pc-windows-msvc`, `aarch64-unknown-linux-musl`,
each as a release archive and a `-debug` archive. The full list is in `SHA256SUMS`.

### Cross-check and anomalies

- `manifest.json` lists six release archives (no debug archives) with the same hashes as `SHA256SUMS` (Z5, Z6).
  `SHA256SUMS` covers the two install scripts and all twelve archives. It does not list `manifest.json`.
  On 2026-11-01 the downloaded `SHA256SUMS` and `manifest.json` matched their API digests. The four
  archives this repository pins were downloaded and matched both `SHA256SUMS` and the API digest.
  The other eight archive lines and the two install-script lines match the API digest; those files
  were not downloaded.
- The first line of `SHA256SUMS` hashes the file itself as the empty string
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, the SHA-256 of zero bytes).
  It is not a valid self-hash. Consumers must skip that line and must not treat it as a pass.
- The checksum file, the manifest and the API digest all come from the same release, so they prove
  transport integrity only. They are not an independent signature. No signature or provenance
  attestation asset exists in the release.
- The unpacked Linux `zccache` member is 27,744,784 bytes, SHA-256
  `fd9fc89ee8273a03f7dabce8459abf41ddf5ab8a27cd9db552384ac9a77af980` (mode 0755). That is not the
  1.15.6 benchmark binary (`f97ae874...cb18cc`, 27,876,808 bytes). Member hashes are in
  [parity/cache/qualification/artifacts.md](../cache/qualification/artifacts.md).

## Pinned compiler and tool statements (FEATURE-MATRIX.md at tag 1.15.11)

All rows are in `docs/FEATURE-MATRIX.md` at the tag (Z7). The file states that it is generated from
`docs/feature-matrix.yaml` and that sccache claims are best effort.

| Area | Statement at the pin | Line in Z7 |
|---|---|---:|
| MSVC `cl.exe` / `link.exe` | `partial`. "zccache parses MSVC-style args and supports `clang-cl`; native `cl.exe`/`link.exe` integration is partial. sccache has first-class MSVC support." | 19 |
| clang-cl | Supported through MSVC-style argument parsing, stated in the same row. No separate row. | 19 |
| C/C++ (GCC and Clang) | `yes` for C/C++ object caching. The matrix names no compiler. The README "Tool Compatibility" list names Clang, clang-tidy, IWYU, emcc, wasm-ld, rustc, rustfmt and clippy, and does **not** list GCC as a drop-in wrapper target. The README does describe GCC and Clang include-trace handling. | 13, README 1311-1317, 587, 780 |
| Link caching | `yes`: snapshots the output directory before the linker, captures sibling `.pdb`, `.wasm`, `.map` and runtime DLLs. | 14 |
| Rust | `yes`: `rustc` caching (`--emit=metadata`, `--emit=link`), `RUSTC_WRAPPER`, `cargo check` and `cargo build`, rustfmt and clippy. | 15, 29-31 |
| CUDA / nvcc | `no`. | 18 |
| Persistent daemon | `yes`, in-memory metadata, filesystem watcher, protocol version in every IPC frame. | 48-55 |
| Hit delivery | reflink, protected hardlink or copy ladder; mtime preserved; hardlink poisoning prevention marked `yes`. | 50-51, 110 |
| Cross-worktree sharing | `ZCCACHE_PATH_REMAP=auto` is `yes`; strict path validation is `yes`. | 64-67 |
| Storage backends | local filesystem `yes`; S3, GCS, Redis, Memcached, Azure Blob `no`; GitHub Actions cache `yes`. | 73-79 |
| Platforms | Linux x86_64 `yes`, Windows x86_64 `yes`, Windows arm64 `yes`. | 86-91 |
| Windows Defender helper | `zccache defender-exclusions add` exists. | 92 |

Consequence recorded for P04 (plan, "Baselines"): native `cl.exe` and `link.exe` are not claimed as
fully supported. Each compiler and invocation mode needs its own qualification. Unqualified modes use
direct compilation with caching disabled. Full build parity must work without a wrapper.

## Daemon and retention interface (README at tag 1.15.11)

Statements from the README (Z8). Names and defaults are as documented. None of this was run.

- **Cache root.** `ZCCACHE_CACHE_DIR` isolates `artifacts/`, `tmp/`, `depgraph/`, `index.bin`, `crashes/`,
  `logs/`, daemon lock files, download daemon state and the default daemon endpoint. Separate roots use
  separate daemons unless `ZCCACHE_ENDPOINT` is set (README 422-437).
- **Retention is owned by the daemon.** No system scheduler is required. The artifact budget defaults to 5%
  of filesystem capacity, clamped to 40-200 GiB and reduced to preserve a 30 GiB recovery free space.
  Override with at most one of `ZCCACHE_CACHE_SIZE_BYTES` or `ZCCACHE_CACHE_SIZE_PERCENT` (1-100).
  At 85% of budget, entries older than four days are evicted in LRU order to 70%. At 100% or low free space,
  LRU eviction applies regardless of age until usage reaches 80%. A daily pass expires entries older than
  30 days while the daemon stays alive. The budget covers allocated artifact files and pending writes. Small
  indexes, logs and metadata are **outside** the budget (README 439-462). P04 must account for those bytes.
- **Namespaces.** `ZCCACHE_DAEMON_NAMESPACE` gives a second daemon identity on the same cache root or user,
  with its own socket or named pipe, lock file and lifecycle log. State lives under
  `<cache>/daemon-state/<namespace>`. `ZCCACHE_DAEMON_STATE_DIR` lets a broker supply a private directory
  (README 464-489).
- **Wire.** All daemon requests use prost. `ZCCACHE_DAEMON_WIRE=auto` selects it. Legacy bincode values
  are rejected (README 491-497).
- **Hit delivery.** `ZCCACHE_MODE` is read per compile: `AUTO` (default), `REFLINK_OR_LINK_OR_COPY`, `LINK`,
  `COPY`, `REFLINK`. `AUTO` never hardlinks Rust outputs. `COPY` always makes an independent writable copy
  (README 541-566). Read-only hardlink enforcement defaults on (`ZCCACHE_COW_READONLY`).
- **Safe sharing.** Hardlink delivery and shared caches need the poisoning and concurrency proof the plan
  demands. Default to isolated cache roots and copy or reflink delivery (plan).
- **Session and diagnostics.** `ZCCACHE_SESSION_ID`, `zccache session-stats`, `zccache session-end [--json]`.
  Compile journal is JSONL (Z7 line 56).
- **Kill switches.** `ZCCACHE_DISABLE=1`, `ZCCACHE_STAGED_ARTIFACTS=off`, `ZCCACHE_QUIET=1`.
- **Maturity.** The README "Status" section still says "Early development - architecture and scaffolding
  phase" (README 1300-1302) while the release is 1.15.11. `docs/FEATURE-MATRIX.md` and `README.md`
  at this commit are byte-identical to the 1.15.6 copies (SHA-256 `4f80dce5...6391cf` and
  `6d8450dc...46bb71`). `versioned_subdir()` is still `v` plus the crate version, so state lives in
  `v1.15.11/`. Treat qualification evidence as the only truth.

## Sources

- Z1: <https://github.com/forge-ci/zccache/releases/tag/1.15.11>.
- Z2: <https://api.github.com/repos/forge-ci/zccache/git/ref/tags/1.15.11>, object type `commit`, sha `e5bc38be49dbd88963167e343256b31cca8c1678`.
- Z3: <https://github.com/forge-ci/zccache/commit/e5bc38be49dbd88963167e343256b31cca8c1678>.
- Z4: <https://api.github.com/repos/forge-ci/zccache/releases/tags/1.15.11>, read 2026-11-01.
- Z5: <https://github.com/forge-ci/zccache/releases/download/1.15.11/SHA256SUMS>.
- Z6: <https://github.com/forge-ci/zccache/releases/download/1.15.11/manifest.json>.
- Z7: <https://github.com/forge-ci/zccache/blob/e5bc38be49dbd88963167e343256b31cca8c1678/docs/FEATURE-MATRIX.md> (same content as the `1.15.11` tag path).
- Z8: <https://github.com/forge-ci/zccache/blob/e5bc38be49dbd88963167e343256b31cca8c1678/README.md>.
