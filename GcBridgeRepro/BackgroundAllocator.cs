using System.Diagnostics;

namespace GcBridgeRepro;

/// <summary>
/// Background threads that allocate managed garbage at a fixed rate - the stand-in for an IDE's
/// Roslyn work on the thread pool. This is what drives the managed GC frequency; it creates no
/// Java peers itself, so every bridge round it causes is processing the UI thread's dead peers.
/// </summary>
sealed class BackgroundAllocator
{
    readonly CancellationTokenSource _cts = new();
    readonly List<Thread> _threads = new();

    // One in 32 objects is parked here, overwriting a random older one, so part of the garbage
    // survives a gen0 GC or two the way syntax trees and caches do instead of dying instantly.
    readonly object?[] _survivors = new object?[1 << 16];

    public void Start(int threads, int totalMBps)
    {
        if (threads <= 0 || totalMBps <= 0)
            return;

        long bytesPerSecPerThread = totalMBps * 1024L * 1024 / threads;
        for (int i = 0; i < threads; i++)
        {
            int seed = i;
            var thread = new Thread(() => Run(seed, bytesPerSecPerThread, _cts.Token))
            {
                IsBackground = true,
                Name = $"alloc-{i}",
            };
            _threads.Add(thread);
            thread.Start();
        }
    }

    /// <summary>Stops and joins the threads. Blocks, so call it off the UI thread.</summary>
    public void Stop()
    {
        _cts.Cancel();
        foreach (var thread in _threads)
            thread.Join();
        Array.Clear(_survivors);
    }

    void Run(int seed, long bytesPerSec, CancellationToken ct)
    {
        var rng = new Random(seed);
        long start = GC.GetAllocatedBytesForCurrentThread();
        var clock = Stopwatch.StartNew();
        while (!ct.IsCancellationRequested)
        {
            for (int i = 0; i < 512; i++)
            {
                var node = new Node { Value = i, Payload = new byte[16 + rng.Next(128)] };
                if ((i & 31) == 0)
                    _survivors[rng.Next(_survivors.Length)] = node;
            }

            double allocatedSec = (GC.GetAllocatedBytesForCurrentThread() - start) / (double)bytesPerSec;
            double aheadSec = allocatedSec - clock.Elapsed.TotalSeconds;
            if (aheadSec > 0.001)
                Thread.Sleep(TimeSpan.FromSeconds(aheadSec));
        }
    }
}
