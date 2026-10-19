# zccache 1.15.6 pin

Pinned candidate for the sccache replacement (plan, "Baselines, zccache and provenance"). Facts were
fetched on 2026-10-19 through the GitHub API and raw file URLs. **No release binary was downloaded,
unpacked or executed.** `install.sh` and `install.ps1` were not downloaded. The owner's benchmark
directory was not touched.

## Identity

| Item | Value | Source |
|---|---|---|
| Repository | `zackees/zccache` | Z1 |
| Git tag | `1.15.6` (no `v` prefix) | Z1 |
| Tag resolves to commit | `15ec9537af0d219e07b72ce2b3f97d5f68d72b5e` (a commit object, not an annotated tag) | Z2 |
| Commit date and subject | 2026-10-17T22:19:05Z, `fix(pch): preserve shared input timestamps with private compiler views (#1958)` | Z3 |
| Release `zccache 1.15.6` | published 2026-10-17T22:36:57Z, not draft, not prerelease, `target_commitish` is `main` | Z4 |
| Matches the plan's pin | yes, the commit equals the plan value | PLAN.md |

## Release assets

Sizes and SHA-256 values come from the release API `digest` field. They match the published
`SHA256SUMS` file for every archive and install script, and with `manifest.json` for the six release
archives (compared by script on 2026-10-19, see "Cross-check"). The downloaded `SHA256SUMS` and `manifest.json`
text files themselves hash to their API digests. Download URL pattern: `https://github.com/zackees/zccache/releases/download/1.15.6/<asset>`.

### Linux x86_64 musl and Windows x86_64 (the two target families)

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `zccache-v1.15.6-x86_64-unknown-linux-musl.tar.gz` | 12389072 | `885a109c758808480ebda6b92ac0c55ae55ff2638f0ef850423bb185f28e59f7` |
| `zccache-v1.15.6-x86_64-unknown-linux-musl-debug.tar.gz` | 29806744 | `6eccf0034b23df2fa9f6f523e43a5c2335847e6eb956de8b2e2a284651afaecd` |
| `zccache-v1.15.6-x86_64-pc-windows-msvc.zip` | 10545387 | `a9e2b079946d00757a56fea3dacd8a47f9cb4bcbfe8c427ffd719ced59fd949b` |
| `zccache-v1.15.6-x86_64-pc-windows-msvc-debug.zip` | 34900341 | `619e41467ea832454c0a5fa8ab009497274279f8bbfe8ad4a39bc18784901ceb` |

### Release support files

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `SHA256SUMS` | 1636 | `6b5c2b96c99ab876814cedf3c6c1801d80dc2491fb823fcd8b58f3662c0231c3` |
| `manifest.json` | 2006 | `ed7f2aaf46ec7c6a1abc777625a03c8e4d9e6fa153be9dfe334edb37ccb71500` |
| `install.sh` | 6470 | `31a62a81f95f83ae4eba8abde6cf14e843eb71c1e569018f24533102dc1ad95a` |
| `install.ps1` | 5462 | `56bfe5ed3841f97873439a8f5b504c6904ccd4e61854bc89fe9ee3f09137748d` |

### Other targets published (names only, out of scope for these profiles)

`aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-pc-windows-msvc`, `aarch64-unknown-linux-musl`,
each as a release archive and a `-debug` archive. The full list is in `SHA256SUMS`.

### Cross-check and anomalies

- `manifest.json` lists six release archives (no debug archives) with the same hashes as `SHA256SUMS` (Z5, Z6).
  `SHA256SUMS` covers the two install scripts and all twelve archives. It does not list `manifest.json`.
  Result of the script comparison: all 14 archives and install scripts match `SHA256SUMS`; the six manifest entries match; `SHA256SUMS` and `manifest.json` match their API digests by direct hashing.
- The first line of `SHA256SUMS` hashes the file itself as the empty string
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, the SHA-256 of zero bytes).
  It is not a valid self-hash. Consumers must skip that line and must not treat it as a pass.
- The checksum file, the manifest and the API digest all come from the same release, so they prove
  transport integrity only. They are not an independent signature. No signature or provenance
  attestation asset exists in the release.
- The plan records an owner-tested Linux musl binary (27,876,808 bytes, SHA-256
  `f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc`). That is the unpacked
  binary, not the archive above. **NOT VERIFIED** against the release: matching requires unpacking the
  archive, which this task does not do. P04 must unpack in a scratch directory and compare.

## Pinned compiler and tool statements (FEATURE-MATRIX.md at tag 1.15.6)

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

## Daemon and retention interface (README at tag 1.15.6)

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
  phase" (README 1300-1302) while the release is 1.15.6. Treat qualification evidence as the only truth.

## Sources

- Z1: <https://github.com/zackees/zccache/releases/tag/1.15.6>.
- Z2: <https://api.github.com/repos/zackees/zccache/git/ref/tags/1.15.6>, object type `commit`, sha `15ec9537af0d219e07b72ce2b3f97d5f68d72b5e`.
- Z3: <https://github.com/zackees/zccache/commit/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e>.
- Z4: <https://api.github.com/repos/zackees/zccache/releases/tags/1.15.6>, read 2026-10-19.
- Z5: <https://github.com/zackees/zccache/releases/download/1.15.6/SHA256SUMS>.
- Z6: <https://github.com/zackees/zccache/releases/download/1.15.6/manifest.json>.
- Z7: <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/docs/FEATURE-MATRIX.md> (same content as the `1.15.6` tag path).
- Z8: <https://github.com/zackees/zccache/blob/15ec9537af0d219e07b72ce2b3f97d5f68d72b5e/README.md>.
