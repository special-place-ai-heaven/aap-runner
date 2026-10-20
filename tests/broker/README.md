# Broker client tests

Pester 5 suite for `supervisor/broker/aap-broker.psm1`, for Windows PowerShell 5.1 and
PowerShell 7. CI runs it once the coordinator adds `tests/broker` to the Pester `Run.Path`
(see `supervisor/broker/INTEGRATION.md`). No test starts `wsl.exe`: replies come from a fake
invoker, and the transport tests start `cmd.exe`, `findstr.exe` and `PING.EXE`, hidden.

| File | Topic |
|---|---|
| `BrokerTestHelpers.ps1` | Shared setup, dot-sourced by every `*.Tests.ps1` (not discovered by Pester) |
| `aap-broker.Fixtures.Tests.ps1` | The client validator agrees with `parity/contracts/validate.py` |
| `aap-broker.Requests.Tests.ps1` | What the client writes to the broker |
| `aap-broker.Replies.Tests.ps1` | How broker answers map to outcomes |
| `aap-broker.SecretMarker.Tests.ps1` | The JIT config never surfaces as text |
| `aap-broker.Transport.Tests.ps1` | The hidden process runner |

## Antivirus: write PowerShell that does not look obfuscated

On 2026-10-20 the owner's real-time antivirus (Malwarebytes, through AMSI) quarantined an early
draft of this suite and its scratch launcher as `RiskWare.ObfuscatedPowershell`. The quarantined
draft no longer exists, so the exact trigger inside it could not be bisected afterwards. It
combined these patterns, and the rewrite removed all of them:

- child processes started with `-EncodedCommand` and base64 payloads;
- SecureString to BSTR marshaling (`SecureStringToBSTR`, `PtrToStringBSTR`, `PtrToStringAuto`);
- strings built from `[char]` codes and `\u` escapes, and JSON concatenated by hand.

Rules for P09, P10 and later PowerShell in this repo:

- Keep secrets as `byte[]` and compare them through `[Text.Encoding]`. Never marshal a SecureString.
- Build synthetic markers at runtime from a short ASCII string (`'SYNTHETIC-...' + [guid]`).
- No `Invoke-Expression`, no `-EncodedCommand`, no long base64 literals, no `-bxor` string tricks,
  no `Add-Type` with P/Invoke in tests.
- Build JSON as dictionaries and serialize them; keep files short and split by topic.

**How to check a file.** AMSI scans every script block when it is compiled. Compile the whole
file, then each top-level statement and each `function` and `It` block, with
`[scriptblock]::Create($text)` inside a `try`. A block that AMSI flags throws an error whose
message contains "malicious"; the smallest such block is the trigger. Every file here compiles
clean on Windows PowerShell 5.1 (2026-10-20). If a file is ever flagged, stop editing it and
tell the coordinator the path and the rule name; never split strings or encode text to get past
the scanner.
