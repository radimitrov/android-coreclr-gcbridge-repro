using System.Diagnostics;
using System.Runtime.InteropServices;
using Android.Views;

namespace GcBridgeRepro;

/// <summary>
/// The UI-thread side of the workload and its measurement. Runs once per vsync through the
/// Choreographer for the length of a run, and each frame does what a MAUI screen does:
/// <list type="bullet">
/// <item>creates Java peers and drops them without Dispose (views, listeners, event args), and</item>
/// <item>reads WeakReferences to live managed objects (WeakEventManager behind every binding).</item>
/// </list>
/// It measures two things: the gap between consecutive frames (any stall of the UI thread, from
/// whatever cause, including the peer lookup dotnet/android does to dispatch this very callback), and
/// the time spent inside each <c>WeakReference.TryGetTarget</c> - a direct reading of the bridge wait,
/// since an unblocked read takes tens of nanoseconds.
/// </summary>
sealed class FrameProbe : Java.Lang.Object, Choreographer.IFrameCallback
{
    /// <summary>A weak read at least this long is counted as blocked.</summary>
    public const double BlockedThresholdMs = 1.0;

    /// <summary>A frame gap at least this long is written to logcat when it ends.</summary>
    const double LongGapLogMs = 250;

    readonly ReproOptions _options;
    readonly Action<int> _onSecondsLeft;
    readonly TaskCompletionSource _done = new();

    // The targets are kept strongly reachable here, like live subscribers: the reads must succeed,
    // and on .NET 10 they still wait, because the wait is for any weak handle while a bridge round
    // is active, not just for the objects that round is deciding about.
    readonly object[] _weakTargets;
    readonly WeakReference<object>[] _weak;

    long _end;
    long _last;
    int _lastSecondsLeft = -1;

    public List<double> GapsMs { get; } = new(8192);
    public List<double> WorkMs { get; } = new(8192);
    public long WeakReads { get; private set; }
    public long WeakBlockedReads { get; private set; }
    public double WeakBlockedMs { get; private set; }
    public double WeakMaxMs { get; private set; }
    long _peersCreated;
    public long PeersCreated => Interlocked.Read(ref _peersCreated);

    /// <summary>The longest single peer step (creating the list, or one <c>list.Add(new Peer())</c>) on the UI thread.</summary>
    public double PeerMaxMs { get; private set; }

    /// <summary>The same, for the background churner when <see cref="ReproOptions.PeersOnBackground"/> is set.</summary>
    public double BackgroundPeerMaxMs { get; private set; }

    /// <summary>The longest stall of <see cref="SampleSuspension"/>, a thread that touches no peers.</summary>
    public double SamplerMaxGapMs { get; private set; }

    // Set only with ReproOptions.RootCallback: a managed root, so the GC never treats this callback as dead.
    static FrameProbe? s_rooted;

    Thread? _churner;
    Thread? _sampler;
    Thread? _watchdog;
    volatile bool _stopChurner;
    long _lastFrame;

    public FrameProbe(ReproOptions options, Action<int> onSecondsLeft)
    {
        _options = options;
        _onSecondsLeft = onSecondsLeft;
        _weakTargets = new object[256];
        _weak = new WeakReference<object>[_weakTargets.Length];
        for (int i = 0; i < _weakTargets.Length; i++)
        {
            _weakTargets[i] = new Node { Value = i };
            _weak[i] = new WeakReference<object>(_weakTargets[i]);
        }
    }

    /// <summary>Starts posting frame callbacks; completes after the configured duration. UI thread only.</summary>
    public Task RunAsync()
    {
        _end = Stopwatch.GetTimestamp() + _options.DurationSec * Stopwatch.Frequency;
        s_rooted = _options.RootCallback != 0 ? this : null;
        if (_options.PeersPerFrame > 0 && _options.PeersOnBackground != 0)
        {
            _churner = new Thread(ChurnPeersInBackground) { IsBackground = true, Name = "peer-churner" };
            _churner.Start();
        }
        _sampler = new Thread(SampleSuspension) { IsBackground = true, Name = "suspension-sampler" };
        _sampler.Start();
        _watchdog = new Thread(AnnounceFreezes) { IsBackground = true, Name = "freeze-watchdog" };
        _watchdog.Start();
        Choreographer.Instance!.PostFrameCallback(this);
        return _done.Task;
    }

    // Wakes every millisecond and does nothing but read the clock: no peers, no weak references, no
    // allocation. It only stalls when the runtime suspends managed threads (a stop-the-world GC) or
    // the CPU is starved, so a UI freeze it does not share is a wait specific to the UI thread.
    void SampleSuspension()
    {
        long last = Stopwatch.GetTimestamp();
        int gen0 = GC.CollectionCount(0);
        while (!_stopChurner)
        {
            Thread.Sleep(1);
            long now = Stopwatch.GetTimestamp();
            double gap = Ms(now - last);
            if (gap > SamplerMaxGapMs)
                SamplerMaxGapMs = gap;
            if (gap >= 100)
            {
                int gen0Now = GC.CollectionCount(0);
                Android.Util.Log.Info(MainActivity.Tag, $"SAMPLER {gap:F0} ms ended, gen0 +{gen0Now - gen0}");
                gen0 = gen0Now;
            }
            last = now;
        }
    }

    // Writes "FREEZE" to logcat once per freeze, as soon as the UI thread has gone 200 ms without a
    // frame - so run-repro.ps1 can take a native stack dump (debuggerd, rooted devices only) while the
    // freeze is still going on. It writes through liblog directly: the Java Log binding is Java interop,
    // and during these freezes threads doing interop stall, while threads that don't keep running.
    void AnnounceFreezes()
    {
        long announced = 0;
        while (!_stopChurner)
        {
            Thread.Sleep(50);
            long last = Interlocked.Read(ref _lastFrame);
            if (last == 0 || last == announced)
                continue;
            double gap = Ms(Stopwatch.GetTimestamp() - last);
            if (gap < 200)
                continue;
            announced = last;
            AndroidLogWrite(4 /* ANDROID_LOG_INFO */, MainActivity.Tag, $"FREEZE {gap:F0} ms in progress");
        }
    }

    [DllImport("log", EntryPoint = "__android_log_write")]
    static extern int AndroidLogWrite(int priority, string tag, string text);

    /// <summary>
    /// Resolves the liblog P/Invoke on the calling thread. Call it from the main thread at startup: the
    /// .NET for Android host resolves an unknown library slowly off the main thread.
    /// </summary>
    public static void PrelinkLog() => Marshal.Prelink(typeof(FrameProbe).GetMethod(nameof(AndroidLogWrite),
        System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!);

    // The same peer churn as the frame callback, at the same 60 Hz rate, on a background thread.
    void ChurnPeersInBackground()
    {
        long period = Stopwatch.Frequency / 60;
        long next = Stopwatch.GetTimestamp();
        while (!_stopChurner)
        {
            BackgroundPeerMaxMs = Math.Max(BackgroundPeerMaxMs, CreatePeers());
            next += period;
            long wait = next - Stopwatch.GetTimestamp();
            if (wait > 0)
                Thread.Sleep(TimeSpan.FromSeconds(wait / (double)Stopwatch.Frequency));
            else
                next = Stopwatch.GetTimestamp();
        }
    }

    /// <summary>
    /// Creates one frame's worth of dead peers - a bound Java type holding managed-subclass peers, so
    /// the dead set has Java-side cross references for the bridge to resolve, as real view trees do -
    /// and returns the longest single step, so a wait inside peer creation shows up by itself.
    /// </summary>
    double CreatePeers()
    {
        long t0 = Stopwatch.GetTimestamp();
        var list = new Java.Util.ArrayList();
        double max = Ms(Stopwatch.GetTimestamp() - t0);
        for (int i = 0; i < _options.PeersPerFrame; i++)
        {
            t0 = Stopwatch.GetTimestamp();
            list.Add(new Peer());
            max = Math.Max(max, Ms(Stopwatch.GetTimestamp() - t0));
        }
        Interlocked.Add(ref _peersCreated, _options.PeersPerFrame);
        if (max >= LongGapLogMs)
            Android.Util.Log.Info(MainActivity.Tag, $"PEER {max:F0} ms on {Thread.CurrentThread.Name ?? "ui"}");
        return max;
    }

    public void DoFrame(long frameTimeNanos)
    {
        long now = Stopwatch.GetTimestamp();
        if (_last != 0)
        {
            double gap = Ms(now - _last);
            GapsMs.Add(gap);
            // A long stall, logged as it ends: lined up against ART's "Explicit concurrent ... GC"
            // line (written when the bridge's Runtime.gc() returns), the logcat timestamps split it
            // into the time before, during and after the Java collection.
            if (gap >= LongGapLogMs)
                Android.Util.Log.Info(MainActivity.Tag, $"GAP {gap:F0} ms ended");
        }
        _last = now;
        Interlocked.Exchange(ref _lastFrame, now);

        if (now >= _end)
        {
            GC.KeepAlive(_weakTargets);
            _stopChurner = true;
            _churner?.Join();
            _sampler?.Join();
            _watchdog?.Join();
            _done.TrySetResult();
            return;
        }

        if (_options.PeersPerFrame > 0 && _options.PeersOnBackground == 0)
            PeerMaxMs = Math.Max(PeerMaxMs, CreatePeers());

        for (int i = 0; i < _options.WeakReadsPerFrame; i++)
        {
            long t0 = Stopwatch.GetTimestamp();
            _weak[i % _weak.Length].TryGetTarget(out var target);
            double ms = Ms(Stopwatch.GetTimestamp() - t0);
            GC.KeepAlive(target);
            WeakReads++;
            if (ms >= BlockedThresholdMs)
            {
                WeakBlockedReads++;
                WeakBlockedMs += ms;
            }
            if (ms > WeakMaxMs)
                WeakMaxMs = ms;
        }

        WorkMs.Add(Ms(Stopwatch.GetTimestamp() - now));

        int secondsLeft = (int)((_end - now) / Stopwatch.Frequency);
        if (secondsLeft != _lastSecondsLeft)
        {
            _lastSecondsLeft = secondsLeft;
            _onSecondsLeft(secondsLeft);
        }

        Choreographer.Instance!.PostFrameCallback(this);
    }

    static double Ms(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;
}

/// <summary>A managed subclass of a Java type: a Java peer with a managed half, like a MAUI listener.</summary>
sealed class Peer : Java.Lang.Object
{
}
