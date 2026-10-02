# GcBridgeRepro

A self-contained .NET for Android app that measures what the GC bridge costs the UI thread on
**CoreCLR** compared with **Mono**, with the same code and workload in every APK. It was written for
[dotnet/runtime#131952](https://github.com/dotnet/runtime/pull/131952) (selective WeakReference
waits during bridge processing), after the question there of whether CoreCLR is actually worse
than Mono, and whether bridge waits can add up to an ANR.

No MAUI. The UI-thread weak-reference traffic MAUI produces (WeakEventManager behind every binding)
is reproduced directly, and the waits inside dotnet/android's own peer lookups happen anyway on every
Java→managed callback, including the Choreographer callback the probe runs in.

## What the app does

A run builds a live heap, then for `durationSec` seconds:

| Part | Thread | What it stands for |
|---|---|---|
| `LiveHeaps` | once, before the run | 1,000,000 live Java objects (16 `LinkedList`s built by Java itself) and 32 MB of live managed objects - a loaded app, so each bridge round's `java.lang.Runtime.gc()` has a real heap to mark |
| `BackgroundAllocator` | 2 background threads | Roslyn-style work: small objects with small arrays at a fixed rate (`allocMBps`), 1 in 32 parked in a ring so part of it survives gen0. Creates no Java peers |
| `FrameProbe` | UI thread, every vsync | creates `peersPerFrame` Java peers (a `java.util.ArrayList` holding managed `Java.Lang.Object` subclasses) and drops them without `Dispose`, then does `weakReadsPerFrame` `WeakReference.TryGetTarget` reads on live managed objects, timing each one |
| sampler | 1 background thread | wakes every millisecond and only reads the clock - no peers, no interop, no allocation - to tell a stop-the-world GC apart from a wait only interop threads hit |

The display is pinned to 60 Hz and an indeterminate `ProgressBar` animates, so the UI thread renders
every frame (adaptive-refresh ROMs otherwise change rate under a static screen).

### What it reports

One `RESULT key=value ...` logcat line per run (tag `GcBridgeRepro`), also shown on screen:

- `gen0`/`gen1`/`gen2`, `allocMB` - managed collections and allocation during the run. `allocMB / gen0` is the effective gen0 budget.
- `artGc`, `artGcMs` - ART collections (`android.os.Debug.getRuntimeStat`). With almost no Java
  allocation in the run, nearly every one is a bridge round's `Runtime.gc()`. The script also counts
  ART's `Explicit concurrent ... GC` logcat lines as a cross-check (`artExplicitGcLines` in the CSV).
- `fps`, `gapP50/P90/P99/Max`, `gaps100`, `gaps700` - the gap between consecutive frame callbacks,
  i.e. how long the UI thread was unavailable, from whatever cause.
- `lostMs` - Σ(gap − 16.7 ms) over gaps longer than 1.5 frames: UI time lost against a perfect cadence.
- `weakBlocked`, `weakBlockedMs`, `weakMaxMs` - weak reads that took ≥ 1 ms (an unblocked read is tens of ns).
- `workMax`, `peerMaxMs`, `bgPeerMaxMs` - the longest frame-callback body, the longest single peer
  step (`new Peer()` / `list.Add`) on the UI thread, and on the background churner. A freeze much
  longer than `workMax` happened outside the callback's body, in the Java→managed dispatch.
- `FREEZE <n> ms in progress` - logged through liblog (not Java interop, which stalls during these
  freezes) once the UI has gone 200 ms without a frame; on a rooted device the script takes a
  `debuggerd -b` dump right then.
- `samplerMaxGapMs` - the longest stall of a managed thread that does no Java interop at all. It only
  stalls when the runtime suspends managed threads, so it separates a stop-the-world GC from a wait
  that only threads doing interop hit. Long sampler stalls also log `SAMPLER <n> ms ended`.
- `GCCONFIG` (separate line) - every `GC.GetConfigurationVariables()` value on CoreCLR.
- `GAP <n> ms ended` (separate lines) - every frame gap of 250 ms or more as it ends; `run-repro.ps1` lines these up against ART's explicit-GC log line to split a freeze into before / during / after the Java collection.

## Variants

The only differences between the APKs are the runtime, the .NET version, and an optional fixed gen0
budget. Each variant has its own package id, so all are installed side by side.

| Variant (default set) | Build | Why it is there |
|---|---|---|
| `Mono` | .NET 10, `UseMonoRuntime=true` | the baseline apps migrate from |
| `CoreCLR` | .NET 10, `UseMonoRuntime=false` | CoreCLR as shipped in .NET 10 |
| `CoreCLR-gen0-1000000` | .NET 10 CoreCLR + `DOTNET_GCgen0size=0x1000000` (16 MB) | a middle gen0 budget |
| `CoreCLR-gen0-2000000` | .NET 10 CoreCLR + `DOTNET_GCgen0size=0x2000000` (32 MB) | a large gen0 budget: fewer rounds, more dead peers per round |
| `CoreCLR-net11` | .NET 11 RC1, CoreCLR (Mono is not supported on Android from .NET 11 on: NETSDK1242) | the runtime every app moves to |
| `CoreCLR-net12` | .NET 12 daily, CoreCLR | the first runtime with [dotnet/runtime#131952](https://github.com/dotnet/runtime/pull/131952) |
| `CoreCLR-net12-gen0-2000000` | .NET 12 daily + 32 MB gen0 | whether the fix takes the long rounds off the UI thread |

Any `<CoreCLR\|Mono>[-net<N>][-gen0-<hex bytes>]` works, e.g. `CoreCLR-gen0-400000` (4 MB, Mono's
nursery size). All are Release builds with each runtime's default Release settings (trimming,
AOT/R2R, marshal methods). Debug would distort the comparison: no AOT/R2R, fast deployment, and a
debugger agent on Mono.

.NET 11 and 12 are optional - the CoreCLR-vs-Mono comparison is entirely .NET 10 - but they show
which part of the problem .NET 11 already fixes, and what #131952 changes on top.

About `CoreCLR-net12`: main still calls its current TFM `net11.0`, and dotnet/android main ships only
`net11.0-android` on the .NET 12 SDK band, so this variant is `net11.0-android` built with the .NET 12
daily SDK, which maps that TFM to its own runtime pack. The report's runtime column shows the
`12.0.0-alpha` runtime that actually ran. It is not a pure A/B against .NET 11 RC1 - everything else
that changed on main comes along - but #131952 is the change to the bridge path.

## Scenarios

| Scenario | Length | allocMBps | peersPerFrame | Purpose |
|---|---:|---:|---:|---|
| `idle` | 30 s | 0 | 20 | a UI that churns peers (scrolling, layout) with no background work |
| `light` | 30 s | 4 | 20 | light background work |
| `heavy` | 30 s | 32 | 20 | heavy background work (an IDE compiling/analysing) |
| `heavy-nopeers` | 30 s | 32 | 0 | control: the same managed GC load with no dead peers, so no bridge rounds |
| `burst` | 60 s | 0 | 60 | heavy peer churn only: how long a single bridge round gets |
| `burst-bgpeers` | 60 s | 0 | 60 (background thread) | the same churn off the UI thread: does the UI still wait when it touches no peers itself? |
| `burst-rooted` (opt-in) | 60 s | 0 | 60 (background thread) | burst-bgpeers with the frame callback also held by a managed static: is the wait for the callback being a bridge candidate? |

All other knobs keep their defaults (`ReproOptions.cs`); any of them can be passed with `--ei`.

## Running it

One command, from this folder:

```powershell
./run-repro.ps1            # 7 variants x 6 scenarios x 3 reps (~2.5 h)
./run-repro.ps1 -Reps 1    # one pass (~50 min)
./run-repro.ps1 -Variants Mono,CoreCLR,CoreCLR-gen0-2000000          # .NET 10 only
./run-repro.ps1 -Variants Mono,CoreCLR -Scenarios idle,heavy -SkipBuild -SkipInstall
```

Requirements: the .NET 10 SDK with the `android` workload, the Android SDK, and exactly one arm64
(or x86_64) device on adb (`-Serial` to choose one). The script builds every variant, installs them,
runs every scenario on every variant (alternating the order each rep so thermal drift does not favour
one runtime), and writes **one report**: `results\<timestamp>
eport.md`. Next to it are
`results.csv` (every metric of every run) and `logs\` (the full logcat of each run).

For a .NET 11 or 12 variant it installs that SDK and an Android workload into `.dotnet11\` /
`.dotnet12\` next to the script on first use (`install-dotnet11.ps1`, `install-dotnet12.ps1`; nothing
system-wide - delete the folder to undo). The .NET 12 one lays the .NET 12 Android manifest out by
hand, because the workload installer refuses it over a .NET 10 pack it lists that is not published
on any public feed; see the notes in the script. Some OEM ROMs (Xiaomi HyperOS) ask to confirm each install on the device; the script
retries while you tap Install.

**Native stacks.** On a rooted device (or an emulator image without Google Play, after `adb root`) the
script also dumps every thread with `debuggerd -b` while a freeze is going on, saves the dumps in
`logs\`, and puts the UI thread and the bridge thread into the report. `libcoreclr.so` frames are
symbolized automatically when the Android NDK is installed (`llvm-symbolizer`): the script reads each
APK's libcoreclr build-id and fetches its symbols from Microsoft's public symbol server into
`.symbols\`. Without root the report says the stacks were not captured.

A single run by hand:

```
adb shell am start -n com.repro.gcbridge.coreclr/com.repro.gcbridge.MainActivity     --ez autostart true --es scenario idle --ei durationSec 30 --ei allocMBps 0
adb logcat -s GcBridgeRepro
```

## Results

[`RESULTS.md`](RESULTS.md) is the report of one full default run (`./run-repro.ps1`: 7 variants x 6
scenarios x 3 reps) on a Xiaomi 2410CRP4CG (Snapdragon 7+ Gen 3, 8 cores, Android 16). What it shows:

1. **Managed GCs alone cost the UI nothing.** 4,800 CoreCLR GCs in 30 s with no dead peers
   (`heavy-nopeers`) still run at 60 fps. The cost comes from bridge rounds, which need dead peers.
2. **.NET 10 CoreCLR runs far more bridge rounds than Mono**, because its gen0 budget on Android is
   the 256 KB floor (0.21 MB allocated per GC). release/10.0 defines `TARGET_ANDROID` instead of
   `TARGET_LINUX`, which compiles out the cache-size detection in `gcenv.unix.cpp`. Result: 18 rounds
   vs 0 at `idle` (1.5 s vs 15 ms of lost UI time), and 603 vs 244 under `heavy` load.
   [dotnet/runtime#128826](https://github.com/dotnet/runtime/pull/128826) fixes it in .NET 11
   (~5 MB per GC; 193 rounds and 33.5 fps under load, against Mono's 244 rounds and 27.2 fps).
3. **[dotnet/runtime#131952](https://github.com/dotnet/runtime/pull/131952) removes most of the UI
   cost of bridge rounds under background load.** Same GC work, same 193 bridge rounds: .NET 11 RC1
   runs `heavy` at 33.5 fps with 14.6 s of lost UI time, the .NET 12 daily (with the fix) at 59.5 fps
   with 0.6 s; `light` goes from 56.3 to 59.7 fps and its worst freeze from 155 to 68 ms. Every
   Java→managed callback looks its peer up through `WeakReference.TryGetTarget`, which on .NET 10/11
   waits out the whole round; with the fix it only waits for peers pending in that round.
4. **It does not fix the long freezes in large rounds.** In `burst` (~50k dead peers per round), one
   round still freezes the UI for 1.4–1.7 s on .NET 12, with or without a 32 MB gen0 (.NET 11: 0.7 s
   with smaller rounds; Mono: 0.2 s for a similar number of dead peers). ~90% of each freeze comes
   *after* `Runtime.gc()` returns (e.g. 1,684 ms = 93 + 51 Java GC + 1,540). The freeze diagnosis
   narrows it down:
   - On .NET 10/11 the UI waits *inside* its own peer work (UI peer step ≈ the freeze), as the weak
     reads would predict.
   - On .NET 12 the UI's frame work stays short (117 ms max) and the freeze happens *outside* the
     callback's body, in the Java→managed dispatch. In `burst-bgpeers`, where the UI touches no
     peers at all, it still freezes 1.4–1.6 s, while the background thread creating peers stalls
     just as long.
   - A managed thread that does no Java interop never stalls (sampler: ≤ 102 ms everywhere), so
     this is not a stop-the-world GC: only threads that do Java interop wait.
   - Holding the frame callback in a managed static (`burst-rooted`) changes nothing, so it is not
     the callback being a bridge candidate either.
   - Every `burst` GC on .NET 12 is a full gen2 collection (gen0/1/2 = 6/6/6; .NET 11 does gen0
     GCs there, 6/2/0), and 2 of the 6 started no round of their own, so each round carried more
     dead peers.
   Native stacks taken during these freezes (rooted emulator, [`RESULTS-rooted-emulator.md`](RESULTS-rooted-emulator.md),
   symbolized against Microsoft's libcoreclr symbols) show what that time is, on .NET 11 and .NET 12
   alike: the UI thread waits in `GCHandle_InternalGetBridgeWait` → `Interop::WaitForGCBridgeFinish`,
   while the bridge thread is in `FinishCrossReferenceProcessing` → `Ref_NullBridgeObjectsWeakRefs`
   → `NullBridgeObjectWeakRef`. That function visits every weak handle in the process and, for each
   one, scans the whole array of unreachable bridge objects linearly (`// FIXME Store these objects
   in a hashtable in order to optimize lookup`, `src/coreclr/gc/objecthandle.cpp`, the same in
   release/10.0, release/11.0 and main). Every registered peer has a `WeakReference` in dotnet/android's
   registry, so the cost is O(weak handles x dead peers) - quadratic in peer count, which matches the
   data: ~34k dead peers per round freeze 0.7 s, ~50k freeze 1.5-1.7 s (and (50/34)^2 x 0.7 = 1.5).
5. **gen0 budget on .NET 10:** 16 MB sits between the default and 32 MB under load (50.2 vs 54.8 fps
   in `heavy`) and freezes as long as 32 MB in `burst` (1.7 s), so it is not a better trade-off than
   32 MB. With the fix (.NET 12), the budget barely matters under load (59.5 fps default, 58.6 at 32 MB).

The frame gaps never reached 5 s on this device, so the repro shows freezes, not ANRs. The
per-round cost grows with the number of dead peers, and a low-end phone does the same work several
times slower.
