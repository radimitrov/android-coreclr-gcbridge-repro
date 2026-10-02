using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace GcBridgeRepro;

/// <summary>Process-wide GC counters, read before and after the measured phase.</summary>
readonly record struct Counters(
    int Gen0, int Gen1, int Gen2, long AllocatedBytes, TimeSpan ManagedPause,
    long ArtGcCount, long ArtGcTimeMs, long ArtBlockingGcCount, long ArtBlockingGcTimeMs)
{
    public static Counters Read() => new(
        GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2),
        GC.GetTotalAllocatedBytes(false), GC.GetTotalPauseDuration(),
        ArtStat("art.gc.gc-count"), ArtStat("art.gc.gc-time"),
        ArtStat("art.gc.blocking-gc-count"), ArtStat("art.gc.blocking-gc-time"));

    // ART's own counters. With almost no Java allocation in the measured phase, nearly every ART
    // collection is one the bridge asked for (java.lang.Runtime.gc()), so this counts bridge rounds.
    static long ArtStat(string name) =>
        long.TryParse(Android.OS.Debug.GetRuntimeStat(name), out long value) ? value : -1;
}

/// <summary>Formats a run as one <c>key=value</c> line: logged for the script, shown on screen.</summary>
static class Report
{
    public static string RuntimeName =>
#if REPRO_MONO
        "Mono";
#else
        "CoreCLR";
#endif

    /// <summary>What actually loaded, independent of the build flag above.</summary>
    public static string RuntimeActual => Type.GetType("Mono.RuntimeStructs") is not null ? "Mono" : "CoreCLR";

    /// <summary>The display's refresh rate: the frame gap a UI thread with nothing in its way would show.</summary>
    public static float RefreshHz { get; set; } = 60;

    public static string Header() =>
        $"package={Android.App.Application.Context.PackageName} " +
        $"runtime={RuntimeName} runtimeActual={RuntimeActual} framework=\"{RuntimeInformation.FrameworkDescription}\" " +
        $"gcGen0size={GcConfigValue("GCgen0size")} gcGen0MaxBudget={GcConfigValue("GCGen0MaxBudget")} " +
        $"refreshHz={Math.Round(RefreshHz)} " +
        $"device=\"{Android.OS.Build.Manufacturer} {Android.OS.Build.Model}\" api={(int)Android.OS.Build.VERSION.SdkInt} " +
        $"cpus={Environment.ProcessorCount} " +
        $"javaHeapMaxMB={Java.Lang.Runtime.GetRuntime()!.MaxMemory() / (1024 * 1024)}";

    // CoreCLR's effective GC settings: GCgen0size is the configured floor (0 = derived from the CPU
    // cache size), GCGen0MaxBudget the ceiling the GC computed at startup. Mono has no such API; its
    // nursery is a fixed 4 MB unless MONO_GC_PARAMS says otherwise.
    static IReadOnlyDictionary<string, object> GcConfigurationVariables()
    {
        try
        {
            return GC.GetConfigurationVariables();
        }
        catch (Exception)
        {
            return new Dictionary<string, object>();
        }
    }

    static string GcConfigValue(string name) =>
        GcConfigurationVariables().TryGetValue(name, out var value)
            ? Convert.ToString(value, CultureInfo.InvariantCulture) ?? "?"
            : "n/a";

    /// <summary>Every GC configuration variable the runtime reports, for the log.</summary>
    public static string GcConfig() =>
        string.Join(" ", GcConfigurationVariables().OrderBy(kv => kv.Key)
            .Select(kv => $"{kv.Key}={Convert.ToString(kv.Value, CultureInfo.InvariantCulture)}"));

    public static string Format(ReproOptions o, Counters before, Counters after, FrameProbe probe)
    {
        var gaps = probe.GapsMs.ToArray();
        Array.Sort(gaps);
        var work = probe.WorkMs.ToArray();
        Array.Sort(work);

        var sb = new StringBuilder();
        void Add(string key, object value) =>
            sb.Append(key).Append('=').Append(Convert.ToString(value, CultureInfo.InvariantCulture)).Append(' ');
        static double R(double v) => Math.Round(v, 2);

        sb.Append(Header()).Append(' ');
        sb.Append(o.Describe()).Append(' ');
        Add("javaLiveBuilt", LiveHeaps.JavaObjects);
        Add("managedLiveBuiltMB", LiveHeaps.ManagedMB);

        // Managed GC: how often the background work collected, and what it allocated.
        Add("gen0", after.Gen0 - before.Gen0);
        Add("gen1", after.Gen1 - before.Gen1);
        Add("gen2", after.Gen2 - before.Gen2);
        Add("allocMB", (after.AllocatedBytes - before.AllocatedBytes) / (1024 * 1024));
        Add("managedPauseMs", R((after.ManagedPause - before.ManagedPause).TotalMilliseconds));

        // ART: bridge rounds and what they cost.
        Add("artGc", after.ArtGcCount - before.ArtGcCount);
        Add("artGcMs", after.ArtGcTimeMs - before.ArtGcTimeMs);
        Add("artBlockingGc", after.ArtBlockingGcCount - before.ArtBlockingGcCount);
        Add("artBlockingGcMs", after.ArtBlockingGcTimeMs - before.ArtBlockingGcTimeMs);

        // UI thread: frame gaps.
        // lostMs: UI-thread time lost against a perfect frame cadence, the single number to compare.
        double periodMs = 1000.0 / RefreshHz;
        Add("frames", gaps.Length);
        Add("fps", R(gaps.Length / (double)o.DurationSec));
        Add("lostMs", R(gaps.Where(g => g > periodMs * 1.5).Sum(g => g - periodMs)));
        Add("gapP50", R(Percentile(gaps, 0.50)));
        Add("gapP90", R(Percentile(gaps, 0.90)));
        Add("gapP99", R(Percentile(gaps, 0.99)));
        Add("gapMax", R(gaps.Length > 0 ? gaps[^1] : 0));
        Add("gaps50", gaps.Count(g => g > 50));
        Add("gaps100", gaps.Count(g => g > 100));
        Add("gaps700", gaps.Count(g => g > 700));
        Add("gaps5000", gaps.Count(g => g > 5000));
        Add("stallMs", R(gaps.Where(g => g > 50).Sum()));
        Add("workP50", R(Percentile(work, 0.50)));
        Add("workMax", R(work.Length > 0 ? work[^1] : 0));
        Add("peerMaxMs", R(probe.PeerMaxMs));
        Add("bgPeerMaxMs", R(probe.BackgroundPeerMaxMs));
        Add("samplerMaxGapMs", R(probe.SamplerMaxGapMs));

        // UI thread: weak reads.
        Add("weakReads", probe.WeakReads);
        Add("weakBlocked", probe.WeakBlockedReads);
        Add("weakBlockedMs", R(probe.WeakBlockedMs));
        Add("weakMaxMs", R(probe.WeakMaxMs));
        Add("peers", probe.PeersCreated);
        return sb.ToString().TrimEnd();
    }

    static double Percentile(double[] sorted, double p) =>
        sorted.Length == 0 ? 0 : sorted[Math.Min(sorted.Length - 1, (int)(p * sorted.Length))];
}
