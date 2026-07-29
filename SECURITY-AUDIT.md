# Security audit of upstream TurboFieldfare

An independent review done before adopting upstream into this fork, on
2026-07-29. Recorded here so it does not have to be repeated from scratch.

**Scope:** all 345 files at upstream commit
`f8abc4422e33a8808d5a5c1032a0e97ed5aa5118` (v0.3) — Swift, Metal, shell, Ruby,
and CI configuration.

**Verdict: no malicious behaviour found.** The security engineering is above
average for a project this young; the redirect token handling in particular is
careful work most projects get wrong.

> ⚠️ **This audit is valid for commit `f8abc44` only.** Re-check before adopting
> future upstream changes. `Scripts/sync-upstream.sh` shows you exactly which
> commits are new — skim them.

---

## Provenance

Apache-2.0. 348 stars, 12 forks at time of audit. Single author, Andrey
Mikhaylov (iOS/Metal engineer, ex-Prisma AI), GitHub account since 2014, real
LinkedIn presence. 12 commits and 5 tagged releases over 9 days. The repo was 12
days old and narrow-purpose — young, but the history is coherent and
incremental, not a dump-and-run.

Residual risk to weigh: young, single-maintainer project.

## Findings — all clean

- **Network surface.** The only external host in the entire codebase is
  `huggingface.co`, plus `127.0.0.1`. Every other host is an RFC-6761 reserved
  `.test` domain used in test fixtures. No telemetry, no analytics, no beacons.
- **Model pinning.** Downloads `mlx-community/gemma-4-26b-a4b-it-4bit` pinned to
  commit `0d77464eeb233a2da68ebf9d7dc4edaac7db956d`. Verified: that repo is
  public, ungated, 25.8k downloads, and its head SHA matches the pin exactly.
- **Token handling.** The Hugging Face auth token is attached *only* when the
  request host matches the base host. On redirect,
  `authorizationMayBeForwarded` latches to false after any cross-host hop and is
  never re-attached — so a redirect that bounces back to `huggingface.co` still
  cannot recover the token. This defends against redirect-bounce token theft.
- **Redirects.** HTTPS-only, bounded count. Metadata requests refuse cross-host
  redirects entirely.
- **Integrity.** Every packed file and the manifest are SHA-256 verified
  (CryptoKit, not `Insecure.*`) before an install is accepted. Path traversal is
  rejected (`..`, leading `/`, `?`, `#`). A completed install reports
  `Verified 37 files (14291915755 bytes)`.
- **No TLS bypass.** Zero occurrences of `NSAllowsArbitraryLoads`,
  `didReceiveChallenge`, or certificate-trust overrides. System TLS validation
  is fully intact.
- **Process execution.** Three `Process()` call sites, all `/bin/launchctl` in
  the `gui/$UID` domain — user session, never `system/`, no root, no privilege
  escalation. They start and stop the sibling `TurboFieldfareDecodeService`
  binary located next to the app. The launchd plist is written to a temp
  directory, has `KeepAlive: false`, and is removed on a `defer`. **No
  persistence.**
- **No persistence or snooping.** No LaunchAgents or LaunchDaemons installed, no
  cron, no shell-profile edits, no Keychain or `SecItem` access, no `CGEvent` or
  accessibility APIs, no camera, contacts, or photos. Pasteboard access is
  **write-only** (the UI's copy buttons); it is never read.
- **No obfuscation.** No base64 payloads, no encoded blobs, no long opaque
  literals. Every `xor` match is the xorshift64 PRNG in the sampler.
- **Supply chain.** Dependencies are Apple (`swift-nio`, `swift-crypto`,
  `swift-collections`, `swift-atomics`, `swift-asn1`, `swift-system`),
  Hugging Face (`swift-transformers`, `swift-jinja`, `swift-huggingface`),
  `ibireme/yyjson`, and `mattt/EventSource` — all reputable, all pinned to exact
  revisions in `Package.resolved`.
- **No build-time execution.** No SwiftPM plugins, no `binaryTarget`, no
  `unsafeFlags`, no prebuild commands — the main vector for code that fires
  during `swift build` is simply absent. No git hooks. No unexpected binaries.
- **CI.** Least-privilege (`permissions: contents: read`), pinned
  `actions/checkout@v4`, no secrets, no `curl | bash`.
- **Local server.** Hardcoded `bind(host: "127.0.0.1")` — loopback only, with no
  option to bind `0.0.0.0`. Matches its documentation. It has no authentication
  or TLS, so keep it on loopback as upstream advises.

---

## How the memory claim actually works

Worth understanding, because it is the part that sounds too good to be true.

Gemma 4 26B-A4B is a mixture-of-experts model: 26B total parameters but only
~3.9B active per token. TurboFieldfare keeps the 1.35 GB shared core plus the
FP16 KV cache resident in RAM, and streams only the experts each token routes to
from SSD via bounded parallel `pread` into Metal-visible buffers, backed by a
16-slot LFU cache per layer.

So the ~2 GB figure is a genuine *RAM* number, but it is bought with **~14.3 GB
of disk** and SSD read bandwidth on every token. It is not compression — it is
paging. A real and legitimate technique, and not a red flag.

For scale, upstream cites mlx-lm on the same model needing 8.3–9.8 GB RSS and
14.7–15.3 GB of GPU allocation.

Measured results for this fork are in [`MACOS14.md`](MACOS14.md).
