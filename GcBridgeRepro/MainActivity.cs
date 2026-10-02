using Android.Content.PM;
using Android.Graphics;
using Android.Util;
using Android.Views;

namespace GcBridgeRepro;

[Activity(
    Label = "@string/app_name",
    Name = "com.repro.gcbridge.MainActivity",
    MainLauncher = true,
    Exported = true,
    LaunchMode = LaunchMode.SingleTask,
    ConfigurationChanges = ConfigChanges.Orientation | ConfigChanges.ScreenSize | ConfigChanges.ScreenLayout |
                           ConfigChanges.Keyboard | ConfigChanges.KeyboardHidden | ConfigChanges.UiMode)]
public class MainActivity : Activity
{
    public const string Tag = "GcBridgeRepro";

    TextView _status = null!;
    TextView _result = null!;
    Button _run = null!;
    bool _busy;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        Window!.AddFlags(WindowManagerFlags.KeepScreenOn);
        FrameProbe.PrelinkLog();
        // Pin 60 Hz: adaptive-refresh ROMs otherwise switch rates under a static screen, and the
        // frame gaps would measure the display's mode changes instead of the UI thread.
        var attributes = Window.Attributes!;
        attributes.PreferredRefreshRate = 60;
        Window.Attributes = attributes;
        Report.RefreshHz = 60;

        int pad = (int)(16 * Resources!.DisplayMetrics!.Density);
        var root = new LinearLayout(this) { Orientation = Orientation.Vertical };
        root.SetPadding(pad, pad, pad, pad);
        root.SetFitsSystemWindows(true);

        _run = new Button(this) { Text = "Run with defaults" };
        _run.Click += (_, _) => _ = RunAsync(new ReproOptions());
        _status = new TextView(this) { Text = Report.Header() };
        _result = new TextView(this) { Typeface = Typeface.Monospace, TextSize = 11 };
        _result.SetTextIsSelectable(true);

        var scroll = new ScrollView(this);
        scroll.AddView(_result);
        // Animates every frame, so the UI thread renders continuously the way a scrolling list does.
        var spinner = new ProgressBar(this) { Indeterminate = true };
        root.AddView(spinner);
        root.AddView(_run);
        root.AddView(_status);
        root.AddView(scroll);
        SetContentView(root);

        if (Intent?.GetBooleanExtra("autostart", false) == true)
            _ = RunAsync(ReproOptions.FromIntent(Intent));
    }

    async Task RunAsync(ReproOptions options)
    {
        if (_busy)
            return;
        _busy = true;
        _run.Enabled = false;
        try
        {
            Log.Info(Tag, "START " + Report.Header() + " " + options.Describe());
            Log.Info(Tag, "GCCONFIG " + Report.GcConfig());
            _status.Text = "Building live heaps...";
            await Task.Run(() =>
            {
                LiveHeaps.EnsureJava(options.JavaLiveObjects);
                LiveHeaps.EnsureManaged(options.ManagedLiveMB);
                // Start from a quiet heap: collect, let that bridge round finish, then settle.
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();
                Thread.Sleep(3000);
            });

            var before = Counters.Read();
            var allocator = new BackgroundAllocator();
            allocator.Start(options.AllocThreads, options.AllocMBps);
            var probe = new FrameProbe(options, secondsLeft => _status.Text = $"{options.Scenario}: {secondsLeft} s left");
            await probe.RunAsync();
            var after = Counters.Read();
            await Task.Run(allocator.Stop);

            string line = Report.Format(options, before, after, probe);
            Log.Info(Tag, "RESULT " + line);
            _status.Text = $"{options.Scenario}: done";
            _result.Text = line.Replace(' ', '\n');
        }
        catch (Exception ex)
        {
            Log.Error(Tag, "FAILED " + ex);
            _status.Text = "Failed: " + ex.Message;
        }
        finally
        {
            _busy = false;
            _run.Enabled = true;
        }
    }
}
