# Running TurboFieldfare on macOS 14 and 15 (Apple Silicon)

Upstream [TurboFieldfare](https://github.com/drumih/turbo-fieldfare) targets
macOS 26, Metal 4, Xcode 26, and Swift 6.2. This fork adds macOS 14 and 15
support from a single source tree — on macOS 26 it still selects the upstream
Metal 4 paths.

**No macOS upgrade and no Xcode install are required.** The macOS 26 dependency
is shallow: a GPU-family enum case, a Metal Shading Language version, one lock
type, and three decorative SwiftUI calls.

Verified on a MacBook Pro M1 Max (32 GB) running macOS 14.8.3: Gemma 4 26B-A4B
generating at a **2.2 GB peak memory footprint** and ~14 tok/s.

## How much needs changing, by OS

| | macOS 14 | macOS 15 | macOS 26 |
| --- | --- | --- | --- |
| MSL version selected | 3.1 | 3.2 | 4.0 |
| Metal 4 tensor-ops prefill | unavailable | unavailable | **available** |
| `Mutex` shim required | yes | no | no |
| SwiftUI shims required | yes | no | no |
| `@preconcurrency import Darwin` | yes | yes | no |

On macOS 15 only the MSL-version and GPU-family changes matter. All of it is
conditional, so one build serves every version.

---

## 1. Toolchain

Swift 6.2 or newer. You do **not** need Xcode, and you do **not** need the
`metal` compiler — shaders ship as `.metal` bundle resources and are compiled at
runtime by `MetalContext`.

The swift.org toolchains declare `os-version min="10.11"`, so they install and
run on macOS 14.

```bash
brew install swiftly
swiftly install 6.2.3
swiftly use 6.2.3
swift --version    # Apple Swift version 6.2.3, Target: arm64-apple-macosx14.0
```

Or install the package to your home directory, no `sudo`:

```bash
curl -LO https://download.swift.org/swift-6.2.3-release/xcode/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE-osx.pkg
installer -pkg swift-6.2.3-RELEASE-osx.pkg -target CurrentUserHomeDirectory
~/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain/usr/bin/swift --version
```

Remove that variant with
`rm -rf ~/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain`.

## 2. Build

```bash
swift build -c release
```

All six products build. Confirm the deployment target took effect:

```bash
otool -l .build/arm64-apple-macosx/release/TurboFieldfareCLI \
  | grep -A3 LC_BUILD_VERSION | grep minos      # minos 14.0
```

If this prints `minos 26.0`, a stale `.build` directory is being reused — run
`rm -rf .build` and rebuild. Binaries stamped `26.0` fail at launch with
`Library not loaded: /usr/lib/swift/libswift_errno.dylib … built for macOS 26.0`.

## 3. Test

```bash
swift build --product TurboFieldfareRepack     # debug copy, see below
swift test -c release --no-parallel
```

Two differences from upstream's `Scripts/test.sh`:

- **`-c release` is required.** Debug expands `#Preview`, whose `PreviewsMacros`
  plugin ships with Xcode rather than the standalone toolchain. Without Xcode a
  debug build fails with *"external macro implementation type
  'PreviewsMacros.SwiftUIView' could not be found"*.
- **`RepackCLITests` expects `.build/debug/TurboFieldfareRepack`.** Build that
  product in debug first, or those three tests fail on a missing binary.

Expected: **514 of 515 tests pass across 108 suites.**

The one failure, `lockIsReleasedWhenOwningProcessIsKilled`, shells out to
`/usr/bin/lockf`, which macOS does not ship. Environmental, unrelated to OS
version or to this fork.

## 4. Install the model

~15 GB transferred, ~14.3 GB on disk. Roughly 6 minutes at 45 MB/s.

```bash
.build/release/TurboFieldfareRepack --output scratch/gemma4.gturbo --overwrite
```

`--resume` requires existing state, so do not pass it on a first run.

```bash
.build/release/TurboFieldfareRepack --output scratch/gemma4.gturbo --overwrite --resume
.build/release/TurboFieldfareRepack --discard-partial --output scratch/gemma4.gturbo
.build/release/TurboFieldfareRepack --verify-install --input-gturbo scratch/gemma4.gturbo
```

Verification reports `Verified 37 files (14291915755 bytes)` and writes
`verified-install.json`.

## 5. Generate

Use `--messages-file`, not `--prompt`. This is an instruction-tuned checkpoint;
`--prompt` is raw completion that bypasses chat formatting and produces
rambling output with `thought` channel tokens leaking through. Expected
behaviour, not a defect.

```bash
echo '[{"role":"user","content":"What is the capital of France?"}]' > /tmp/m.json
.build/release/TurboFieldfareCLI \
  --model scratch/gemma4.gturbo --messages-file /tmp/m.json \
  --max-new 96 --temperature 0
```

Measure memory with `/usr/bin/time -l` and read `peak memory footprint`.

---

## Measured results

M1 Max (32 GPU cores), 32 GB, macOS 14.8.3, `--temperature 0`:

| Prompt | New tokens | Decode | Peak footprint |
| --- | --- | --- | --- |
| Capital of France | 8 | 7.06 tok/s | 2.20 GB |
| MoE explanation | 113 | 14.66 tok/s | 2.20 GB |
| Fibonacci in C | 700 | 14.15 tok/s | 2.24 GB |

Footprint is flat in generation length — a 700-token run costs 40 MB more than
an 8-token run. Expert streaming and the bounded KV cache behave as designed.

Short runs understate throughput because fixed startup dominates; ~14 tok/s is
the steady-state figure. For scale: upstream reports 5.1–6.3 tok/s on an 8 GB
M2 Air, and a community report gives 5–6 tok/s on an 8-GPU-core M1 MacBook Air.
Throughput tracks GPU cores and memory bandwidth, but the ceiling is SSD expert
streaming rather than compute.

Generated C from the Fibonacci prompt compiles clean under
`cc -Wall -Wextra -O2` and prints the correct sequence.

---

## What this fork changes

| File | Change |
| --- | --- |
| `Package.swift` | Platform floor `.macOS(.v26)`/`.iOS(.v26)` → `.v14`/`.v17`; register `TurboFieldfareCompat` |
| `MetalLanguageVersionCompat.swift` *(new)* | Picks MSL 4.0 / 3.2 / 3.1 by OS version, constructing versions by raw value so no SDK-absent case is named |
| `MetalGPUFamilyCompat.swift` *(new)* | `supportsApple10` via `MTLGPUFamily(rawValue: 1010)`, buildable on SDKs predating `.apple10` |
| `MetalContext.swift` | Uses `MetalLanguageVersionCompat.best` instead of hard-coded `.version4_0` |
| `PrefillAttention.swift` | Apple10 gate routed through `MetalGPUFamilyCompat` |
| `TurboFieldfareCompat` *(new target)* | `NSLock`-backed `Mutex` standing in for `Synchronization.Mutex` (macOS 15+); only `withLock` is used |
| `MacOS14Compat.swift` *(new)* | Gates `containerBackground(for:)`, `Color.mix(with:by:)`, `WindowDragGesture` behind `if #available(macOS 15, *)` |
| 13 files | `import Synchronization` → `import TurboFieldfareCompat` |
| `RepackAudit.swift`, `AppMemorySampler.swift` | `@preconcurrency import Darwin` — this SDK does not annotate `mach_task_self_` as concurrency-safe |
| **Metal shader sources** | **unchanged** |

### Why the shaders need no changes

Upstream already guards every Metal 4 construct:

```c
#if defined(__HAVE_TENSOR__)
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace mpp::tensor_ops;
#endif
```

This covers `prefill.metal` lines 4–7 and 900–1167, and all of
`tensorops.metal`. Below MSL 4.0 the macro is undefined and the tensor-ops
kernels compile out. `MPPPrefillInt4QMM.init` independently catches its own
failure and sets `pipeline = nil`.

Confirmed by compiling the runtime library directly on an M1 Max at MSL 3.1:

```
device: Apple M1 Max
  apple7: true   apple8: false   apple9: false
RUNTIME LIBRARY COMPILED OK — 44 functions
```

### Behavioural differences below macOS 26

- The Metal 4 tensor-ops prefill path is unavailable. Upstream gates it on
  Apple10 (M5), so no pre-M5 GPU ever reached it; `attention_prefill_causal_tiled`
  is used instead. `preferredTensorOpsPathUsesSafeHardwareFallback` asserts the
  fallback produces byte-identical output. Upstream commit notes cite a 2.4x
  prefill speedup (11.24x on attention alone) for that path, so an M5 on
  macOS 26 does get materially faster prefill — and this fork still selects it
  there.
- On macOS 14 only: the app window omits its background gradient and the status
  HUD is not drag-repositionable. Cosmetic.

---

## Staying current with upstream

```bash
git remote add upstream https://github.com/drumih/turbo-fieldfare.git
git fetch upstream
git rebase upstream/main
```

The delta is small and mostly additive — four new files plus localized edits.
`Package.swift` is the only likely conflict, and only on the platform-floor
lines.

The cleanest long-term fix would be upstream lowering its platform floor and
gating macOS 26 APIs behind availability checks, which is what the compat
helpers here demonstrate. That would make this fork unnecessary.
