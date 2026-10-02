# GC bridge repro report

2026-10-02 23:07 - Google Android SDK built for x86_64, Android 9 (API 28), , x86_64. 1 rep(s) per cell, medians shown; the variant order alternates every rep.

## Variants

| variant | runtime | gen0 config (GCgen0size / GCGen0MaxBudget) | allocated per managed GC |
|---|---|---|---:|
| Mono | Mono, .NET 10.0.12 | 4 MB nursery (sgen default) | - MB |
| CoreCLR-net11 | CoreCLR, .NET 11.0.0-rc.1.26425.128 | auto / 8388608 | 9.25 MB |
| CoreCLR-net12 | CoreCLR, .NET 12.0.0-alpha.1.26480.102 | auto / 8388608 | 1.08 MB |

## Scenarios

- **burst** (60 s): 3x the peer churn, no background work: how long one round gets

All scenarios: 20 dead Java peers created on the UI thread per frame (60 in burst), 200 WeakReference reads per frame, 1,000,000 live Java objects, 32 MB live managed heap, display pinned to 60 Hz.

## Results

| scenario | variant | managed GCs | bridge rounds | Java GC ms | fps | UI time lost ms | worst freeze ms | freezes >100 ms | >700 ms | weak-read wait ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| burst | Mono | 0 | **4** | 427 | 54.9 | **2,514** | **264** | 4 | 0 | 60 |
| burst | CoreCLR-net11 | 4 | **4** | 441 | 52.5 | **4,970** | **1,242** | 4 | 4 | 22 |
| burst | CoreCLR-net12 | 24 | **4** | 461 | 51.4 | **6,086** | **1,416** | 4 | 4 | 20 |

## Worst freeze per variant, split

The longest UI-thread gap of each variant across all runs, split on logcat timestamps around the bridge round's `java.lang.Runtime.gc()`. "Before" is the managed GC plus dotnet/android preparing every dead peer for the Java collection; "after" is switching them back, clearing references and the managed finish callback.

| variant | scenario | freeze ms | before Java GC | Java GC | after Java GC |
|---|---|---:|---:|---:|---:|
| Mono | burst | 264 | 59 | 105 | 100 |
| CoreCLR-net11 | burst | 1,242 | 51 | 101 | 1,090 |
| CoreCLR-net12 | burst | 1,416 | 287 | 94 | 1,035 |

(A "-" split means the gap was under 250 ms, or no Java GC ended inside it.)

## Freeze diagnosis

Where the long freezes sit. **UI frame work**: the longest time spent inside one frame callback; **UI peer step**: the longest single `new Peer()` / `list.Add` on the UI thread; **churner stall**: the same for the background thread in burst-bgpeers; **sampler stall**: the longest stall of a managed thread that does no Java interop at all (it only stalls if the runtime suspends managed threads). A freeze much longer than the UI frame work happened outside the frame callback's body - in the Java->managed dispatch. GC generations are managed collections during the run.

| scenario | variant | worst freeze ms | UI frame work ms | UI peer step ms | churner stall ms | sampler stall ms | GCs gen0 / gen1 / gen2 |
|---|---|---:|---:|---:|---:|---:|---|
| burst | Mono | 264 | 254 | 237 | 0 | 58 | 0 / 4 / 4 |
| burst | CoreCLR-net11 | 1,242 | 1,230 | 1,199 | 0 | 109 | 4 / 4 / 4 |
| burst | CoreCLR-net12 | 1,416 | 239 | 49 | 0 | 32 | 24 / 24 / 24 |

## Native stacks during freezes

Taken with `debuggerd -b` 200 ms or more into a freeze; the dump itself pauses the process briefly, so the metrics of those runs are slightly perturbed. Below: the main (UI) thread of the first dump per variant, and any thread inside the runtime's bridge processing; every thread is in `logs\*-stack*.txt`. `libcoreclr.so` frames are symbolized when the Android NDK is installed and Microsoft's symbol server has the build (symbols cached in `.symbols\`).

**Mono** - `logs\Mono-burst-1-stack1.txt` (raw: no symbols)

```
"o.gcbridge.mono" sysTid=9963   <- main (UI) thread
  #00 pc 000000000007e1da  /system/lib64/libc.so (__epoll_pwait+10)
  #01 pc 0000000000013d12  /system/lib64/libutils.so (android::Looper::pollInner(int)+162)
  #02 pc 0000000000013bc9  /system/lib64/libutils.so (android::Looper::pollOnce(int, int*, int*, void**)+41)
  #03 pc 000000000011cec5  /system/lib64/libandroid_runtime.so (android::android_os_MessageQueue_nativePollOnce(_JNIEnv*, _jobject*, long, int)+37)
  #04 pc 00000000003dce2b  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (android.media.MediaExtractor.seekTo [DEDUPED]+187)
  #05 pc 0000000000ac201c  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (android.os.MessageQueue.next+220)
  #06 pc 0000000000abf866  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (android.os.Looper.loop+518)
  #07 pc 00000000008921f7  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (android.app.ActivityThread.main+583)
  #08 pc 00000000005c3c16  /system/lib64/libart.so (art_quick_invoke_static_stub+806)
  #09 pc 00000000000cf483  /system/lib64/libart.so (art::ArtMethod::Invoke(art::Thread*, unsigned int*, unsigned int, art::JValue*, char const*)+243)
  #10 pc 00000000004b7389  /system/lib64/libart.so (art::(anonymous namespace)::InvokeWithArgArray(art::ScopedObjectAccessAlreadyRunnable const&, art::ArtMethod*, art::(anonymous namespace)::ArgArray*, art::JValue*, char const*)+89)
  #11 pc 00000000004b9167  /system/lib64/libart.so (art::InvokeMethod(art::ScopedObjectAccessAlreadyRunnable const&, _jobject*, _jobject*, _jobject*, unsigned long)+1447)
  #12 pc 0000000000433708  /system/lib64/libart.so (art::Method_invoke(_JNIEnv*, _jobject*, _jobject*, _jobjectArray*)+56)
  #13 pc 000000000011c623  /system/framework/x86_64/boot.oat (offset 0x110000) (java.lang.Class.getDeclaredMethodInternal [DEDUPED]+227)
  #14 pc 0000000000bfd88d  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (com.android.internal.os.RuntimeInit$MethodAndArgsCaller.run+141)
  #15 pc 0000000000c04b24  /system/framework/x86_64/boot-framework.oat (offset 0x3c3000) (com.android.internal.os.ZygoteInit.main+2804)
  #16 pc 00000000005c3c16  /system/lib64/libart.so (art_quick_invoke_static_stub+806)
  #17 pc 00000000000cf483  /system/lib64/libart.so (art::ArtMethod::Invoke(art::Thread*, unsigned int*, unsigned int, art::JValue*, char const*)+243)
  #18 pc 00000000004b7389  /system/lib64/libart.so (art::(anonymous namespace)::InvokeWithArgArray(art::ScopedObjectAccessAlreadyRunnable const&, art::ArtMethod*, art::(anonymous namespace)::ArgArray*, art::JValue*, char const*)+89)
  #19 pc 00000000004b6f52  /system/lib64/libart.so (art::InvokeWithVarArgs(art::ScopedObjectAccessAlreadyRunnable const&, _jobject*, _jmethodID*, __va_list_tag*)+434)
  #20 pc 00000000003a0ab7  /system/lib64/libart.so (art::JNI::CallStaticVoidMethodV(_JNIEnv*, _jclass*, _jmethodID*, __va_list_tag*)+791)
  #21 pc 00000000000b2099  /system/lib64/libandroid_runtime.so (_JNIEnv::CallStaticVoidMethod(_jclass*, _jmethodID*, ...)+153)
  #22 pc 00000000000b5260  /system/lib64/libandroid_runtime.so (android::AndroidRuntime::start(char const*, android::Vector<android::String8> const&, bool)+736)
  #23 pc 00000000000021fd  /system/bin/app_process64 (main+1357)
  #24 pc 00000000000c278c  /system/lib64/libc.so (__libc_init+92)

```

**CoreCLR-net11** - `logs\CoreCLR-net11-burst-1-stack2.txt` (symbolized)

```
"dge.coreclr.n11" sysTid=11161   <- main (UI) thread
  #00 pc 0000000000026b96  /system/lib64/libc.so (syscall+22)
  #01 pc 0000000000029cd5  /system/lib64/libc.so (__futex_wait_ex(void volatile*, bool, int, bool, timespec const*)+133)
  #02 pc 000000000009219d  /system/lib64/libc.so (pthread_cond_wait+45)
  #03 libcoreclr.so  ThreadNativeWait
  #04 libcoreclr.so  BlockThread
  #05 libcoreclr.so  InternalWaitForMultipleObjectsEx
  #06 libcoreclr.so  WaitForSingleObject
  #07 libcoreclr.so  CLREventWaitHelper2
  #08 libcoreclr.so  WaitForGCBridgeFinish
  #09 libcoreclr.so  GCHandle_InternalGetBridgeWait
  #10 pc 000000000003a075  /memfd:doublemapper (deleted) (offset 0x351000)

"Thread-3" sysTid=11180   <- bridge processing
  #00 libcoreclr.so  NullBridgeObjectWeakRef
  #01 libcoreclr.so  ScanConsecutiveHandlesWithoutUserData
  #02 libcoreclr.so  SegmentScanByTypeMap
  #03 libcoreclr.so  HndEnumHandles
  #04 libcoreclr.so  Ref_NullBridgeObjectsWeakRefs
  #05 libcoreclr.so  FinishCrossReferenceProcessing
  #06 libcoreclr.so  JavaMarshal_FinishCrossReferenceProcessing
  #07 pc 0000000000011985  /memfd:doublemapper (deleted) (offset 0x351000)

```

**CoreCLR-net12** - `logs\CoreCLR-net12-burst-1-stack1.txt` (symbolized)

```
"dge.coreclr.n12" sysTid=12433   <- main (UI) thread
  #00 pc 0000000000026b96  /system/lib64/libc.so (syscall+22)
  #01 pc 0000000000029cd5  /system/lib64/libc.so (__futex_wait_ex(void volatile*, bool, int, bool, timespec const*)+133)
  #02 pc 000000000009219d  /system/lib64/libc.so (pthread_cond_wait+45)
  #03 libcoreclr.so  minipal_condition_variable_wait_pthread
  #04 libcoreclr.so  Wait
  #05 libcoreclr.so  CLREventWaitHelper2
  #06 libcoreclr.so  WaitForGCBridgeFinish
  #07 libcoreclr.so  GCHandle_InternalGetBridgeWait
  #08 pc 0000000000030485  /memfd:doublemapper (deleted) (offset 0x371000)

"Thread-3" sysTid=12459   <- bridge processing
  #00 libcoreclr.so  NullBridgeObjectWeakRef
  #01 libcoreclr.so  ScanConsecutiveHandlesWithoutUserData
  #02 libcoreclr.so  SegmentScanByTypeMap
  #03 libcoreclr.so  HndEnumHandles
  #04 libcoreclr.so  Ref_NullBridgeObjectsWeakRefs
  #05 libcoreclr.so  FinishCrossReferenceProcessing
  #06 libcoreclr.so  JavaMarshal_FinishCrossReferenceProcessing
  #07 pc 000000000000c75e  /memfd:doublemapper (deleted) (offset 0x371000)

```


## How to read it

- **bridge rounds**: ART explicit collections, one per GC-bridge round (the bridge calls `java.lang.Runtime.gc()`). A managed GC only starts one when it finds dead Java peers - compare heavy with heavy-nopeers.
- **UI time lost**: the sum of (frame gap - 16.7 ms) over gaps longer than 1.5 frames. **Worst freeze**: the longest gap between two frame callbacks.
- **weak-read wait**: time inside the probe's own `WeakReference.TryGetTarget` calls that took >= 1 ms. Most of the UI wait happens elsewhere - in dotnet/android's peer lookup when Java calls into managed code - and shows up only in the frame gaps. Tens of ms here is scheduler noise (Mono shows it with no bridge rounds at all).
- Raw data: `results.csv` (every metric of every run) and `logs\` (full logcat per run).
