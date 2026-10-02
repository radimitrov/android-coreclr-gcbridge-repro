# GC bridge repro report

2026-10-02 22:23 - Xiaomi 2410CRP4CG, Android 16 (API 36), SM7675, arm64-v8a. 3 rep(s) per cell, medians shown; the variant order alternates every rep.

## Variants

| variant | runtime | gen0 config (GCgen0size / GCGen0MaxBudget) | allocated per managed GC |
|---|---|---|---:|
| Mono | Mono, .NET 10.0.12 | 4 MB nursery (sgen default) | 3.96 MB |
| CoreCLR | CoreCLR, .NET 10.0.12 | auto / 6291456 | 0.21 MB |
| CoreCLR-gen0-1000000 | CoreCLR, .NET 10.0.12 | auto / 16777216 | 15.54 MB |
| CoreCLR-gen0-2000000 | CoreCLR, .NET 10.0.12 | auto / 33554432 | 29.00 MB |
| CoreCLR-net11 | CoreCLR, .NET 11.0.0-rc.1.26425.128 | auto / 6291456 | 5.03 MB |
| CoreCLR-net12 | CoreCLR, .NET 12.0.0-alpha.1.26480.102 | auto / 6291456 | 4.92 MB |
| CoreCLR-net12-gen0-2000000 | CoreCLR, .NET 12.0.0-alpha.1.26480.102 | auto / 33554432 | 28.06 MB |

## Scenarios

- **idle** (30 s): UI peer churn only, no background work
- **light** (30 s): plus 4 MB/s of background allocation
- **heavy** (30 s): plus 32 MB/s of background allocation (an IDE compiling)
- **heavy-nopeers** (30 s): control: heavy, but no dead peers, so no bridge rounds
- **burst** (60 s): 3x the peer churn, no background work: how long one round gets
- **burst-bgpeers** (60 s): burst, but the peers are created on a background thread: does the UI still wait?

All scenarios: 20 dead Java peers created on the UI thread per frame (60 in burst), 200 WeakReference reads per frame, 1,000,000 live Java objects, 32 MB live managed heap, display pinned to 60 Hz.

## Results

| scenario | variant | managed GCs | bridge rounds | Java GC ms | fps | UI time lost ms | worst freeze ms | freezes >100 ms | >700 ms | weak-read wait ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| idle | Mono | 0 | **0** | 0 | 60.0 | **15** | **32** | 0 | 0 | 0 |
| idle | CoreCLR | 18 | **18** | 1,324 | 56.8 | **1,526** | **150** | 11 | 0 | 0 |
| idle | CoreCLR-gen0-1000000 | 0 | **0** | 0 | 60.3 | **10** | **27** | 0 | 0 | 0 |
| idle | CoreCLR-gen0-2000000 | 1 | **1** | 62 | 58.7 | **786** | **777** | 1 | 1 | 0 |
| idle | CoreCLR-net11 | 1 | **1** | 68 | 59.1 | **543** | **534** | 1 | 0 | 0 |
| idle | CoreCLR-net12 | 0 | **0** | 0 | 60.3 | **16** | **32** | 0 | 0 | 1 |
| idle | CoreCLR-net12-gen0-2000000 | 0 | **0** | 0 | 60.3 | **16** | **28** | 0 | 0 | 0 |
| light | Mono | 31 | **31** | 2,448 | 54.5 | **2,881** | **131** | 21 | 0 | 6 |
| light | CoreCLR | 29 | **29** | 2,183 | 55.3 | **2,473** | **141** | 17 | 0 | 1 |
| light | CoreCLR-gen0-1000000 | 7 | **7** | 499 | 58.5 | **891** | **183** | 7 | 0 | 0 |
| light | CoreCLR-gen0-2000000 | 3 | **3** | 192 | 59.3 | **527** | **189** | 3 | 0 | 0 |
| light | CoreCLR-net11 | 21 | **21** | 1,600 | 56.3 | **1,965** | **155** | 14 | 0 | 1 |
| light | CoreCLR-net12 | 27 | **27** | 2,028 | 59.7 | **375** | **68** | 0 | 0 | 17 |
| light | CoreCLR-net12-gen0-2000000 | 3 | **3** | 188 | 59.7 | **302** | **134** | 1 | 0 | 1 |
| heavy | Mono | 243 | **244** | 18,264 | 27.2 | **17,922** | **130** | 81 | 0 | 168 |
| heavy | CoreCLR | 4,919 | **603** | 26,486 | 22.2 | **19,984** | **136** | 8 | 0 | 348 |
| heavy | CoreCLR-gen0-1000000 | 61 | **60** | 4,231 | 50.2 | **5,479** | **140** | 40 | 0 | 0 |
| heavy | CoreCLR-gen0-2000000 | 31 | **30** | 1,893 | 54.8 | **2,927** | **142** | 21 | 0 | 0 |
| heavy | CoreCLR-net11 | 194 | **193** | 14,268 | 33.5 | **14,612** | **130** | 90 | 0 | 102 |
| heavy | CoreCLR-net12 | 194 | **193** | 14,197 | 59.5 | **645** | **66** | 0 | 0 | 1 |
| heavy | CoreCLR-net12-gen0-2000000 | 30 | **30** | 1,907 | 58.6 | **1,032** | **75** | 0 | 0 | 5 |
| heavy-nopeers | Mono | 243 | **2** | 159 | 59.7 | **305** | **109** | 1 | 0 | 4 |
| heavy-nopeers | CoreCLR | 4,823 | **4** | 229 | 59.7 | **179** | **78** | 0 | 0 | 35 |
| heavy-nopeers | CoreCLR-gen0-1000000 | 61 | **3** | 170 | 58.7 | **1,154** | **107** | 1 | 0 | 1 |
| heavy-nopeers | CoreCLR-gen0-2000000 | 31 | **3** | 157 | 58.7 | **965** | **92** | 0 | 0 | 0 |
| heavy-nopeers | CoreCLR-net11 | 194 | **3** | 167 | 59.6 | **736** | **72** | 0 | 0 | 2 |
| heavy-nopeers | CoreCLR-net12 | 194 | **3** | 164 | 59.5 | **859** | **68** | 0 | 0 | 11 |
| heavy-nopeers | CoreCLR-net12-gen0-2000000 | 30 | **2** | 108 | 58.6 | **985** | **74** | 0 | 0 | 1 |
| burst | Mono | 0 | **4** | 176 | 59.2 | **768** | **217** | 4 | 0 | 134 |
| burst | CoreCLR | 48 | **48** | 3,710 | 54.7 | **5,289** | **151** | 43 | 0 | 4 |
| burst | CoreCLR-gen0-1000000 | 4 | **4** | 201 | 54.3 | **5,785** | **1,700** | 4 | 4 | 14 |
| burst | CoreCLR-gen0-2000000 | 4 | **4** | 191 | 54.7 | **5,430** | **1,716** | 4 | 4 | 12 |
| burst | CoreCLR-net11 | 6 | **6** | 359 | 56.2 | **3,958** | **734** | 6 | 3 | 25 |
| burst | CoreCLR-net12 | 6 | **4** | 206 | 54.2 | **5,945** | **1,650** | 4 | 4 | 29 |
| burst | CoreCLR-net12-gen0-2000000 | 6 | **4** | 209 | 54.7 | **5,498** | **1,534** | 4 | 4 | 6 |
| burst-bgpeers | Mono | 0 | **4** | 173 | 59.3 | **719** | **205** | 4 | 0 | 1 |
| burst-bgpeers | CoreCLR | 48 | **48** | 3,731 | 55.2 | **5,135** | **164** | 40 | 0 | 3 |
| burst-bgpeers | CoreCLR-gen0-1000000 | 4 | **4** | 211 | 54.3 | **5,826** | **1,720** | 4 | 4 | 1 |
| burst-bgpeers | CoreCLR-gen0-2000000 | 4 | **4** | 201 | 55.0 | **5,248** | **1,664** | 4 | 4 | 1 |
| burst-bgpeers | CoreCLR-net11 | 6 | **6** | 336 | 56.4 | **3,837** | **747** | 6 | 1 | 0 |
| burst-bgpeers | CoreCLR-net12 | 7 | **5** | 254 | 54.6 | **5,532** | **1,438** | 5 | 4 | 1 |
| burst-bgpeers | CoreCLR-net12-gen0-2000000 | 5 | **4** | 207 | 54.4 | **5,743** | **1,564** | 5 | 4 | 1 |

## Worst freeze per variant, split

The longest UI-thread gap of each variant across all runs, split on logcat timestamps around the bridge round's `java.lang.Runtime.gc()`. "Before" is the managed GC plus dotnet/android preparing every dead peer for the Java collection; "after" is switching them back, clearing references and the managed finish callback.

| variant | scenario | freeze ms | before Java GC | Java GC | after Java GC |
|---|---|---:|---:|---:|---:|
| Mono | burst | 218 | - | - | - |
| CoreCLR | burst-bgpeers | 174 | - | - | - |
| CoreCLR-gen0-1000000 | burst | 1,734 | 100 | 49 | 1,585 |
| CoreCLR-gen0-2000000 | burst | 1,733 | 95 | 48 | 1,590 |
| CoreCLR-net11 | burst-bgpeers | 905 | 74 | 56 | 775 |
| CoreCLR-net12 | burst | 1,684 | 93 | 51 | 1,540 |
| CoreCLR-net12-gen0-2000000 | burst-bgpeers | 1,672 | 12 | 51 | 1,609 |

(A "-" split means the gap was under 250 ms, or no Java GC ended inside it.)

## Freeze diagnosis

Where the long freezes sit. **UI frame work**: the longest time spent inside one frame callback; **UI peer step**: the longest single `new Peer()` / `list.Add` on the UI thread; **churner stall**: the same for the background thread in burst-bgpeers; **sampler stall**: the longest stall of a managed thread that does no Java interop at all (it only stalls if the runtime suspends managed threads). A freeze much longer than the UI frame work happened outside the frame callback's body - in the Java->managed dispatch. GC generations are managed collections during the run.

| scenario | variant | worst freeze ms | UI frame work ms | UI peer step ms | churner stall ms | sampler stall ms | GCs gen0 / gen1 / gen2 |
|---|---|---:|---:|---:|---:|---:|---|
| burst | Mono | 217 | 202 | 200 | 0 | 121 | 0 / 4 / 4 |
| burst | CoreCLR | 151 | 145 | 142 | 0 | 63 | 48 / 4 / 0 |
| burst | CoreCLR-gen0-1000000 | 1,700 | 1,691 | 1,664 | 0 | 98 | 4 / 4 / 4 |
| burst | CoreCLR-gen0-2000000 | 1,716 | 1,709 | 1,689 | 0 | 85 | 4 / 4 / 4 |
| burst | CoreCLR-net11 | 734 | 729 | 703 | 0 | 89 | 6 / 2 / 0 |
| burst | CoreCLR-net12 | 1,650 | 117 | 87 | 0 | 83 | 6 / 6 / 6 |
| burst | CoreCLR-net12-gen0-2000000 | 1,534 | 131 | 89 | 0 | 86 | 6 / 6 / 6 |
| burst-bgpeers | Mono | 205 | 1 | 0 | 200 | 120 | 0 / 4 / 4 |
| burst-bgpeers | CoreCLR | 164 | 2 | 0 | 149 | 61 | 48 / 4 / 0 |
| burst-bgpeers | CoreCLR-gen0-1000000 | 1,720 | 2 | 0 | 1,722 | 102 | 4 / 4 / 4 |
| burst-bgpeers | CoreCLR-gen0-2000000 | 1,664 | 1 | 0 | 1,657 | 85 | 4 / 4 / 4 |
| burst-bgpeers | CoreCLR-net11 | 747 | 1 | 0 | 740 | 89 | 6 / 2 / 0 |
| burst-bgpeers | CoreCLR-net12 | 1,438 | 6 | 0 | 1,465 | 80 | 7 / 7 / 7 |
| burst-bgpeers | CoreCLR-net12-gen0-2000000 | 1,564 | 5 | 0 | 1,551 | 86 | 5 / 5 / 5 |

## How to read it

- **bridge rounds**: ART explicit collections, one per GC-bridge round (the bridge calls `java.lang.Runtime.gc()`). A managed GC only starts one when it finds dead Java peers - compare heavy with heavy-nopeers.
- **UI time lost**: the sum of (frame gap - 16.7 ms) over gaps longer than 1.5 frames. **Worst freeze**: the longest gap between two frame callbacks.
- **weak-read wait**: time inside the probe's own `WeakReference.TryGetTarget` calls that took >= 1 ms. Most of the UI wait happens elsewhere - in dotnet/android's peer lookup when Java calls into managed code - and shows up only in the frame gaps. Tens of ms here is scheduler noise (Mono shows it with no bridge rounds at all).
- Raw data: `results.csv` (every metric of every run) and `logs\` (full logcat per run).
