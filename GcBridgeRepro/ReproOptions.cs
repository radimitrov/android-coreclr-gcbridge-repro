using Android.Content;

namespace GcBridgeRepro;

/// <summary>
/// The workload knobs. Each can be set from the command line with
/// <c>adb shell am start -n &lt;pkg&gt;/com.repro.gcbridge.MainActivity --ez autostart true --ei &lt;name&gt; &lt;value&gt;</c>
/// (and <c>--es scenario &lt;label&gt;</c>); anything not passed keeps the default below.
/// </summary>
sealed class ReproOptions
{
    /// <summary>A free-form label echoed into the result line, so runs can be grouped.</summary>
    public string Scenario = "default";

    /// <summary>How long the measured phase lasts.</summary>
    public int DurationSec = 30;

    /// <summary>Background threads allocating managed garbage (the IDE's Roslyn work on the pool).</summary>
    public int AllocThreads = 2;

    /// <summary>Total managed allocation rate across <see cref="AllocThreads"/>, in MB/s. 0 = no background work.</summary>
    public int AllocMBps = 32;

    /// <summary>Java peers created on the UI thread every frame and dropped without Dispose.</summary>
    public int PeersPerFrame = 20;

    /// <summary>
    /// 1 = create the <see cref="PeersPerFrame"/> peers on a background thread (at the same 60 Hz rate)
    /// instead of in the UI thread's frame callback, which then only reads weak references.
    /// </summary>
    public int PeersOnBackground = 0;

    /// <summary>
    /// 1 = also hold the frame callback in a managed static. By default only Java keeps it alive (the
    /// Choreographer holds the callback), like most listeners, so a GC that covers its generation makes
    /// it a bridge candidate - pending until the round ends - even though it is alive.
    /// </summary>
    public int RootCallback = 0;

    /// <summary>WeakReference reads on the UI thread every frame (what MAUI's WeakEventManager does per binding).</summary>
    public int WeakReadsPerFrame = 200;

    /// <summary>Java objects kept alive for the whole run, so each ART collection has a real heap to mark.</summary>
    public int JavaLiveObjects = 1_000_000;

    /// <summary>Managed objects kept alive for the whole run, in MB (a loaded workspace).</summary>
    public int ManagedLiveMB = 32;

    public static ReproOptions FromIntent(Intent? intent)
    {
        var o = new ReproOptions();
        if (intent is null)
            return o;
        o.Scenario = intent.GetStringExtra("scenario") ?? o.Scenario;
        o.DurationSec = intent.GetIntExtra("durationSec", o.DurationSec);
        o.AllocThreads = intent.GetIntExtra("allocThreads", o.AllocThreads);
        o.AllocMBps = intent.GetIntExtra("allocMBps", o.AllocMBps);
        o.PeersPerFrame = intent.GetIntExtra("peersPerFrame", o.PeersPerFrame);
        o.PeersOnBackground = intent.GetIntExtra("peersOnBackground", o.PeersOnBackground);
        o.RootCallback = intent.GetIntExtra("rootCallback", o.RootCallback);
        o.WeakReadsPerFrame = intent.GetIntExtra("weakReadsPerFrame", o.WeakReadsPerFrame);
        o.JavaLiveObjects = intent.GetIntExtra("javaLiveObjects", o.JavaLiveObjects);
        o.ManagedLiveMB = intent.GetIntExtra("managedLiveMB", o.ManagedLiveMB);
        return o;
    }

    public string Describe() =>
        $"scenario={Scenario} durationSec={DurationSec} allocThreads={AllocThreads} allocMBps={AllocMBps} " +
        $"peersPerFrame={PeersPerFrame} peersOnBackground={PeersOnBackground} rootCallback={RootCallback} weakReadsPerFrame={WeakReadsPerFrame} " +
        $"javaLiveObjects={JavaLiveObjects} managedLiveMB={ManagedLiveMB}";
}
