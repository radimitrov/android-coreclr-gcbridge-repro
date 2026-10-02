<#
.SYNOPSIS
    The whole repro in one command: builds every variant, installs them side by side, runs every
    scenario on every variant in counterbalanced order, and writes ONE report (report.md).

.EXAMPLE
    ./run-repro.ps1                         # full run: 7 variants x 6 scenarios x 3 reps (~2.5 h)
    ./run-repro.ps1 -Reps 1                 # one pass (~50 min)
    ./run-repro.ps1 -Variants Mono,CoreCLR -Scenarios idle,heavy -SkipBuild -SkipInstall

.NOTES
    Variants: <CoreCLR|Mono>[-net<N>][-gen0-<hex bytes>]
      Mono, CoreCLR            .NET 10 (the system SDK)
      CoreCLR-net11            .NET 11 (installed locally into .dotnet11\ on first use; Mono is not
                               supported on Android from .NET 11 on, so there is no Mono-net11)
      CoreCLR-net12            .NET 12 daily, the first runtime with dotnet/runtime#131952 (installed
                               locally into .dotnet12\ on first use)
      CoreCLR-gen0-2000000     .NET 10 with DOTNET_GCgen0size baked in (hex bytes; 2000000 = 32 MB,
                               1000000 = 16 MB); combines with -net<N>, e.g. CoreCLR-net12-gen0-2000000
    Some OEM ROMs (Xiaomi HyperOS) ask to confirm every install on the device; the script waits
    and retries.
#>
param(
    [int]$Reps = 3,
    [string[]]$Variants = @('Mono', 'CoreCLR', 'CoreCLR-gen0-1000000', 'CoreCLR-gen0-2000000',
                            'CoreCLR-net11', 'CoreCLR-net12', 'CoreCLR-net12-gen0-2000000'),
    [string[]]$Scenarios = @('idle', 'light', 'heavy', 'heavy-nopeers', 'burst', 'burst-bgpeers'),
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [string]$Serial
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$project = Join-Path $root 'GcBridgeRepro\GcBridgeRepro.csproj'
$activity = 'com.repro.gcbridge.MainActivity'
$inv = [Globalization.CultureInfo]::InvariantCulture

# Per scenario: how long it runs and the am-start arguments it adds. Everything else keeps the in-app
# defaults (ReproOptions.cs): 20 peers/frame, 200 weak reads/frame, 1M live Java objects, 32 MB live managed.
$scenarioTable = [ordered]@{
    'idle'          = @{ Sec = 30; Args = @('--ei', 'allocMBps', '0'); Text = 'UI peer churn only, no background work' }
    'light'         = @{ Sec = 30; Args = @('--ei', 'allocMBps', '4'); Text = 'plus 4 MB/s of background allocation' }
    'heavy'         = @{ Sec = 30; Args = @('--ei', 'allocMBps', '32'); Text = 'plus 32 MB/s of background allocation (an IDE compiling)' }
    'heavy-nopeers' = @{ Sec = 30; Args = @('--ei', 'allocMBps', '32', '--ei', 'peersPerFrame', '0'); Text = 'control: heavy, but no dead peers, so no bridge rounds' }
    'burst'         = @{ Sec = 60; Args = @('--ei', 'allocMBps', '0', '--ei', 'peersPerFrame', '60'); Text = '3x the peer churn, no background work: how long one round gets' }
    'burst-bgpeers' = @{ Sec = 60; Args = @('--ei', 'allocMBps', '0', '--ei', 'peersPerFrame', '60', '--ei', 'peersOnBackground', '1'); Text = 'burst, but the peers are created on a background thread: does the UI still wait?' }
    'burst-rooted'  = @{ Sec = 60; Args = @('--ei', 'allocMBps', '0', '--ei', 'peersPerFrame', '60', '--ei', 'peersOnBackground', '1', '--ei', 'rootCallback', '1'); Text = 'burst-bgpeers, with the UI frame callback also held by a managed static: is the wait for the callback itself?' }
}

function Write-Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }

function Find-Adb {
    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($sdk -and (Test-Path (Join-Path $sdk 'platform-tools\adb.exe'))) { return Join-Path $sdk 'platform-tools\adb.exe' }
    }
    throw 'adb not found: put it on PATH or set ANDROID_HOME.'
}

$adbExe = Find-Adb
# The SDK adb came from; passed to every build so an SDK never configured in an IDE (the local
# .dotnet11) finds the Android platforms too.
$androidSdk = Split-Path (Split-Path $adbExe -Parent) -Parent
$serialArgs = @()
if ($Serial) { $serialArgs = @('-s', $Serial) }
function Adb { & $adbExe @serialArgs @args }

function Get-VariantInfo([string]$variant) {
    if ($variant -notmatch '^(CoreCLR|Mono)(-net(\d+))?(-gen0-([0-9A-Fa-f]+))?$') { throw "Unknown variant '$variant'." }
    $runtime = $Matches[1]
    $net = if ($Matches[3]) { $Matches[3] } else { '10' }
    $gen0 = $Matches[5]
    if ($runtime -eq 'Mono' -and $net -ne '10') { throw "$variant`: Mono is not supported on Android from .NET 11 on." }
    $package = 'com.repro.gcbridge.' + $runtime.ToLowerInvariant()
    $props = @("-p:ReproRuntime=$runtime", "-p:ReproNet=$net")
    if ($net -ne '10') { $package += ".n$net" }
    if ($gen0) { $package += ".g$gen0"; $props += "-p:ReproGen0Size=$gen0" }
    $dotnet = 'dotnet'
    if ($net -ne '10') { $dotnet = Join-Path $root ".dotnet$net\dotnet.exe" }
    return @{ Props = $props; Package = $package; Dotnet = $dotnet; Net = $net }
}

function ConvertFrom-ResultLine([string]$line) {
    $row = [ordered]@{}
    foreach ($m in [regex]::Matches($line, '(\w+)=("([^"]*)"|(\S+))')) {
        $row[$m.Groups[1].Value] = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { $m.Groups[4].Value }
    }
    return $row
}

function Get-Median([double[]]$values) {
    if ($values.Count -eq 0) { return [double]::NaN }
    $sorted = $values | Sort-Object
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$mid] }
    return ($sorted[$mid - 1] + $sorted[$mid]) / 2
}

function Format-Num($value, [int]$digits = 0) {
    if ($null -eq $value -or [double]::IsNaN([double]$value)) { return '-' }
    return ([math]::Round([double]$value, $digits)).ToString("N$digits", $inv)
}

# Splits the longest UI gap of a run into the time before, during and after the bridge's Java
# collection: the app logs "GAP <n> ms ended" for gaps >= 250 ms, and ART logs
# "Explicit concurrent ... total <t>ms" when the bridge's java.lang.Runtime.gc() returns.
function Get-WorstGapSplit([string[]]$log) {
    $gaps = @(); $gcs = @()
    foreach ($line in $log) {
        if ($line -notmatch '^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})') { continue }
        $t = [datetime]::ParseExact('2000-' + $Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $inv)
        if ($line -match 'GAP (\d+) ms ended') {
            $gaps += [pscustomobject]@{ End = $t; Ms = [double]$Matches[1] }
        }
        elseif ($line -match 'Explicit concurrent .*?total ([\d.]+)(ms|s)') {
            $total = [double]::Parse($Matches[1], $inv)
            if ($Matches[2] -eq 's') { $total *= 1000 }
            $gcs += [pscustomobject]@{ End = $t; Ms = $total }
        }
    }
    $worst = $gaps | Sort-Object Ms -Descending | Select-Object -First 1
    if (-not $worst) { return $null }
    $start = $worst.End.AddMilliseconds(-$worst.Ms)
    $gc = $gcs | Where-Object { $_.End -ge $start -and $_.End -le $worst.End } | Select-Object -Last 1
    if (-not $gc) { return [pscustomobject]@{ Ms = $worst.Ms; Before = $null; JavaGc = $null; After = $null } }
    return [pscustomobject]@{
        Ms     = $worst.Ms
        Before = ($gc.End - $start).TotalMilliseconds - $gc.Ms
        JavaGc = $gc.Ms
        After  = ($worst.End - $gc.End).TotalMilliseconds
    }
}

# ---------------------------------------------------------------- prerequisites

foreach ($s in $Scenarios) { if (-not $scenarioTable.Contains($s)) { throw "Unknown scenario '$s'. Known: $($scenarioTable.Keys -join ', ')." } }
$infos = [ordered]@{}
foreach ($v in $Variants) { $infos[$v] = Get-VariantInfo $v }

$devices = @(Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' })
if (-not $Serial -and $devices.Count -ne 1) { throw "Need exactly one device on adb (found $($devices.Count)); pass -Serial to choose." }
$abi = (Adb shell getprop ro.product.cpu.abi).Trim()
$rid = switch ($abi) {
    'arm64-v8a' { 'android-arm64' }
    'x86_64' { 'android-x64' }
    default { throw "Unsupported device ABI '$abi' (CoreCLR on Android is 64-bit only)." }
}
$device = [ordered]@{
    Model   = '{0} {1}' -f (Adb shell getprop ro.product.manufacturer).Trim(), (Adb shell getprop ro.product.model).Trim()
    Android = '{0} (API {1})' -f (Adb shell getprop ro.build.version.release).Trim(), (Adb shell getprop ro.build.version.sdk).Trim()
    Soc     = (Adb shell getprop ro.soc.model).Trim()
    Abi     = $abi
}
Write-Step "Device: $($device.Model), Android $($device.Android), $($device.Soc), $abi"

# Native stacks during freezes need root: debuggerd refuses to dump a release app otherwise. With
# root, a run that freezes gets `debuggerd -b` dumps taken while the freeze is on (the app logs FREEZE
# through liblog 200 ms into it) - up to 4 attempts, until one catches the UI thread inside the runtime.
$rootShell = $null
if (((Adb shell id) -join '') -match 'uid=0\(') { $rootShell = 'adb' }
elseif (((Adb shell 'command -v su >/dev/null && su -c id 2>/dev/null') -join '') -match 'uid=0\(') { $rootShell = 'su' }
if ($rootShell) { Write-Step "Rooted ($rootShell): native stacks will be captured during freezes" }
else { Write-Step 'Not rooted: native stacks during freezes will not be captured' }

# True when the dump's main (UI) thread is inside the runtime itself - waiting, for these freezes.
function Test-UiInRuntime([string[]]$dump) {
    if (-not $dump) { return $false }
    $pidLine = $dump | Where-Object { $_ -match '^----- pid (\d+) ' } | Select-Object -First 1
    if ($pidLine -notmatch '^----- pid (\d+) ') { return $false }
    $mainPattern = '^"[^"]*" sysTid=' + $Matches[1] + '\s*$'
    $inMain = $false
    foreach ($l in $dump) {
        if ($l -match $mainPattern) { $inMain = $true; continue }
        if ($inMain) {
            if ($l -match '^\s+#\d+') { if ($l -match 'libcoreclr|libmonosgen') { return $true } }
            else { break }
        }
    }
    return $false
}

function Save-NativeStack([string]$pkg, [string]$path) {
    $procId = ((Adb shell pidof $pkg) -join '').Trim()
    if (-not $procId) { return }
    $dump = if ($rootShell -eq 'su') { Adb shell "su -c 'debuggerd -b $procId'" } else { Adb shell "debuggerd -b $procId" }
    $dump | Set-Content -Encoding utf8 $path
}

# The frames of every thread in a `debuggerd -b` dump, keyed by its header line ("<name>" sysTid=<tid>).
function Get-ThreadFrames([string[]]$dump) {
    $threads = [ordered]@{}; $current = $null
    foreach ($l in $dump) {
        if ($l -match '^"[^"]*" sysTid=\d+') { $current = $l.Trim(); $threads[$current] = New-Object System.Collections.Generic.List[string]; continue }
        if ($current -and $l -match '^\s+#\d+') { $threads[$current].Add($l.Trim()) }
    }
    return $threads
}

function Find-NdkTool([string]$name) {
    $ndk = Join-Path $androidSdk 'ndk'
    if (-not (Test-Path $ndk)) { return $null }
    Get-ChildItem $ndk -Directory | Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin\$name.exe" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

# Symbols for the libcoreclr.so inside a variant's APK: its ELF build-id, looked up on Microsoft's
# public symbol server and cached in .symbols\. $null when anything is missing (Mono has no libcoreclr).
function Get-CoreClrSymbols([string]$variant) {
    $readelf = Find-NdkTool 'llvm-readelf'
    if (-not $readelf) { return $null }
    $apk = Get-ChildItem (Join-Path $root "bin\$variant") -Recurse -Filter "$($infos[$variant].Package)-Signed.apk" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*\$rid\*" } | Select-Object -First 1
    if (-not $apk) { return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk.FullName)
    try {
        $entry = $zip.GetEntry("lib/$abi/libcoreclr.so")
        if (-not $entry) { return $null }
        $lib = Join-Path $env:TEMP "libcoreclr-$([guid]::NewGuid()).so"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $lib)
    }
    finally { $zip.Dispose() }
    $buildId = ((& $readelf -n $lib | Out-String) -replace '(?s).*Build ID:\s*([0-9a-f]+).*', '$1').Trim()
    Remove-Item $lib
    if ($buildId -notmatch '^[0-9a-f]{16,}$') { return $null }
    $cache = Join-Path $root '.symbols'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $symbols = Join-Path $cache "libcoreclr-$buildId.debug"
    if (-not (Test-Path $symbols)) {
        try { Invoke-WebRequest "https://msdl.microsoft.com/download/symbols/_.debug/elf-buildid-sym-$buildId/_.debug" -OutFile $symbols -UseBasicParsing }
        catch { if (Test-Path $symbols) { Remove-Item $symbols }; return $null }
    }
    return $symbols
}

# Frames with libcoreclr.so offsets replaced by function names, when symbols are available.
function Format-Frames($frames, [string]$symbols) {
    $symbolizer = if ($symbols) { Find-NdkTool 'llvm-symbolizer' } else { $null }
    foreach ($f in $frames) {
        if ($symbolizer -and $f -match '^(#\d+) pc ([0-9a-f]+)\s+\S*libcoreclr\.so') {
            $name = (& $symbolizer "--obj=$symbols" --functions=short --demangle --no-inlines "0x$($Matches[2])" | Select-Object -First 1)
            "{0} libcoreclr.so  {1}" -f $Matches[1], $name
        }
        else { $f -replace '\s+\(BuildId: [0-9a-f]+\)', '' -replace '/data/app/[^ ]+/lib/[^/]+/', '' }
    }
}

if (-not $SkipBuild) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'dotnet not found: install the .NET 10 SDK.' }
    # .NET 11 and 12 variants build with an SDK installed next to this script. Install it when the
    # folder is missing, or when an interrupted install left the SDK without its Android workload;
    # both installers are safe to rerun.
    $checked = @{}
    foreach ($info in $infos.Values) {
        if ($info.Net -eq '10' -or $checked.ContainsKey($info.Net)) { continue }
        $checked[$info.Net] = $true
        $ready = (Test-Path $info.Dotnet) -and ((& $info.Dotnet workload list | Out-String) -match '(?m)^android\s')
        if ($ready) { continue }
        $installer = Join-Path $root "install-dotnet$($info.Net).ps1"
        if (-not (Test-Path $installer)) { throw "No local SDK for .NET $($info.Net) at $($info.Dotnet), and no $installer." }
        Write-Step "Installing the .NET $($info.Net) SDK and android workload into .dotnet$($info.Net)\ (first run only, nothing system-wide)"
        & $installer
        if (-not ((& $info.Dotnet workload list | Out-String) -match '(?m)^android\s')) { throw "$installer finished without an android workload." }
    }
}

# ---------------------------------------------------------------- build and install

if (-not $SkipBuild) {
    foreach ($v in $Variants) {
        $info = $infos[$v]
        Write-Step "Building $v"
        & $info.Dotnet build $project -c Release "-p:RuntimeIdentifier=$rid" "-p:AndroidSdkDirectory=$androidSdk" @($info.Props) -nologo -v:q
        if ($LASTEXITCODE -ne 0) { throw "Build failed for $v." }
    }
}

if (-not $SkipInstall) {
    foreach ($v in $Variants) {
        $info = $infos[$v]
        $apk = Get-ChildItem (Join-Path $root "bin\$v") -Recurse -Filter "$($info.Package)-Signed.apk" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\$rid\*" } | Select-Object -First 1
        if (-not $apk) { throw "No APK for $v under bin\$v - run without -SkipBuild." }
        Write-Step "Installing $v"
        for ($attempt = 1; ; $attempt++) {
            $out = (Adb install -r $apk.FullName | Out-String)
            if ($out -match 'Success') { break }
            if ($out -match 'USER_RESTRICTED|CANCELED_BY_USER' -and $attempt -lt 4) {
                Write-Warning 'The device asked to confirm the install and it timed out. Tap Install on the device; retrying...'
                continue
            }
            throw "Install failed for $v`: $out"
        }
    }
}

# ---------------------------------------------------------------- runs

$outDir = Join-Path $root ('results\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$logDir = Join-Path $outDir 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
Adb logcat -G 16M | Out-Null

$totalSec = $Reps * $Variants.Count * (($Scenarios | ForEach-Object { $scenarioTable[$_].Sec + 25 }) | Measure-Object -Sum).Sum
Write-Step ("Running {0} variants x {1} scenarios x {2} reps, about {3} min. Leave the device alone." -f $Variants.Count, $Scenarios.Count, $Reps, [math]::Ceiling($totalSec / 60))

$rows = New-Object System.Collections.Generic.List[object]
for ($rep = 1; $rep -le $Reps; $rep++) {
    foreach ($scenario in $Scenarios) {
        $sc = $scenarioTable[$scenario]
        # Alternate the variant order every rep so thermal drift does not favour one of them.
        $order = if ($rep % 2) { $Variants } else { $Variants[($Variants.Count - 1)..0] }
        foreach ($v in $order) {
            $pkg = $infos[$v].Package
            Write-Host ("[rep {0}/{1}] {2,-14} {3,-22}" -f $rep, $Reps, $scenario, $v) -NoNewline
            Adb shell am force-stop $pkg
            Adb logcat -c
            Adb shell am start -n "$pkg/$activity" --ez autostart true --es scenario $scenario --ei durationSec $sc.Sec @($sc.Args) | Out-Null

            $deadline = (Get-Date).AddSeconds($sc.Sec + 120)
            $line = $null
            $stacks = 0
            $caught = $false
            $freezesSeen = 0
            while (-not $line -and (Get-Date) -lt $deadline) {
                # Rooted: poll fast enough to catch a freeze while it is still going on.
                if ($rootShell) { Start-Sleep -Milliseconds 100 } else { Start-Sleep -Seconds 2 }
                $appLog = Adb logcat -d -s 'GcBridgeRepro:*'
                $line = $appLog | Where-Object { $_ -match 'RESULT |FAILED ' } | Select-Object -First 1
                if ($rootShell -and -not $line -and -not $caught -and $stacks -lt 4) {
                    $freezes = @($appLog | Where-Object { $_ -match 'FREEZE ' }).Count
                    if ($freezes -gt $freezesSeen) {
                        $freezesSeen = $freezes
                        $stacks++
                        $stackFile = Join-Path $logDir "$v-$scenario-$rep-stack$stacks.txt"
                        Save-NativeStack $pkg $stackFile
                        $caught = Test-UiInRuntime (Get-Content $stackFile -ErrorAction SilentlyContinue)
                    }
                }
            }
            $log = Adb logcat -d
            $log | Set-Content -Encoding utf8 (Join-Path $logDir "$v-$scenario-$rep.log")
            Adb shell am force-stop $pkg

            if (-not $line -or $line -match 'FAILED ') {
                Write-Host ''
                Write-Warning "No result for $v / $scenario (rep $rep); see logs\$v-$scenario-$rep.log"
                continue
            }
            $row = ConvertFrom-ResultLine ($line -replace '^.*?RESULT ', '')
            $row['variant'] = $v
            $row['rep'] = $rep
            # ART logs every explicit GC; each is one bridge round's java.lang.Runtime.gc().
            $row['artExplicitGcLines'] = @($log | Where-Object { $_ -match 'Explicit concurrent' }).Count
            $split = Get-WorstGapSplit $log
            $row['worstGapBeforeMs'] = if ($split) { $split.Before } else { $null }
            $row['worstGapJavaGcMs'] = if ($split) { $split.JavaGc } else { $null }
            $row['worstGapAfterMs'] = if ($split) { $split.After } else { $null }
            $rows.Add([pscustomobject]$row)
            Write-Host (" bridge rounds {0,4}  fps {1,5}  worst freeze {2,6} ms" -f $row.artGc, $row.fps, $row.gapMax)
            Start-Sleep -Seconds 5
        }
    }
}
$rows | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $outDir 'results.csv')

# ---------------------------------------------------------------- report

function Num($row, [string]$key) {
    $value = $row.$key
    if ($null -eq $value -or $value -eq '') { return [double]::NaN }
    return [double]::Parse([string]$value, $inv)
}
function Median-Of($cell, [string]$key) { Get-Median ([double[]]@($cell | ForEach-Object { Num $_ $key } | Where-Object { -not [double]::IsNaN($_) })) }

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# GC bridge repro report')
$md.Add('')
$md.Add("$(Get-Date -Format 'yyyy-MM-dd HH:mm') - $($device.Model), Android $($device.Android), $($device.Soc), $($device.Abi). " +
    "$Reps rep(s) per cell, medians shown; the variant order alternates every rep.")
$md.Add('')
$md.Add('## Variants')
$md.Add('')
$md.Add('| variant | runtime | gen0 config (GCgen0size / GCGen0MaxBudget) | allocated per managed GC |')
$md.Add('|---|---|---|---:|')
foreach ($v in $Variants) {
    $runs = @($rows | Where-Object { $_.variant -eq $v })
    if ($runs.Count -eq 0) { continue }
    $first = $runs[0]
    $collected = @($runs | Where-Object { (Num $_ 'gen0') -gt 0 })
    $perGc = [double]::NaN
    if ($collected.Count) {
        $perGc = (($collected | ForEach-Object { Num $_ 'allocMB' }) | Measure-Object -Sum).Sum / (($collected | ForEach-Object { Num $_ 'gen0' }) | Measure-Object -Sum).Sum
    }
    # Mono has no GC.GetConfigurationVariables; its nursery is sgen's default. CoreCLR reports no
    # GCgen0size when it is unset, i.e. derived from the CPU cache size.
    $gen0Config = if ($first.runtimeActual -eq 'Mono') { '4 MB nursery (sgen default)' }
                  elseif ($first.gcGen0size -eq 'n/a') { "auto / $($first.gcGen0MaxBudget)" }
                  else { "$($first.gcGen0size) / $($first.gcGen0MaxBudget)" }
    $md.Add("| $v | $($first.runtimeActual), $($first.framework) | $gen0Config | $(Format-Num $perGc 2) MB |")
}
$md.Add('')
$md.Add('## Scenarios')
$md.Add('')
foreach ($s in $Scenarios) { $md.Add("- **$s** ($($scenarioTable[$s].Sec) s): $($scenarioTable[$s].Text)") }
$md.Add('')
$md.Add('All scenarios: 20 dead Java peers created on the UI thread per frame (60 in burst), 200 WeakReference reads per frame, 1,000,000 live Java objects, 32 MB live managed heap, display pinned to 60 Hz.')
$md.Add('')
$md.Add('## Results')
$md.Add('')
$md.Add('| scenario | variant | managed GCs | bridge rounds | Java GC ms | fps | UI time lost ms | worst freeze ms | freezes >100 ms | >700 ms | weak-read wait ms |')
$md.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($s in $Scenarios) {
    foreach ($v in $Variants) {
        $cell = @($rows | Where-Object { $_.scenario -eq $s -and $_.variant -eq $v })
        if ($cell.Count -eq 0) { continue }
        $md.Add(('| {0} | {1} | {2} | **{3}** | {4} | {5} | **{6}** | **{7}** | {8} | {9} | {10} |' -f $s, $v,
                (Format-Num (Median-Of $cell 'gen0')), (Format-Num (Median-Of $cell 'artGc')), (Format-Num (Median-Of $cell 'artGcMs')),
                (Format-Num (Median-Of $cell 'fps') 1), (Format-Num (Median-Of $cell 'lostMs')), (Format-Num (Median-Of $cell 'gapMax')),
                (Format-Num (Median-Of $cell 'gaps100')), (Format-Num (Median-Of $cell 'gaps700')), (Format-Num (Median-Of $cell 'weakBlockedMs'))))
    }
}
$md.Add('')
$md.Add('## Worst freeze per variant, split')
$md.Add('')
$md.Add('The longest UI-thread gap of each variant across all runs, split on logcat timestamps around the bridge round''s `java.lang.Runtime.gc()`. ' +
    '"Before" is the managed GC plus dotnet/android preparing every dead peer for the Java collection; "after" is switching them back, clearing references and the managed finish callback.')
$md.Add('')
$md.Add('| variant | scenario | freeze ms | before Java GC | Java GC | after Java GC |')
$md.Add('|---|---|---:|---:|---:|---:|')
foreach ($v in $Variants) {
    $worst = $rows | Where-Object { $_.variant -eq $v } | Sort-Object { Num $_ 'gapMax' } -Descending | Select-Object -First 1
    if (-not $worst) { continue }
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $v, $worst.scenario, (Format-Num (Num $worst 'gapMax')),
            (Format-Num (Num $worst 'worstGapBeforeMs')), (Format-Num (Num $worst 'worstGapJavaGcMs')), (Format-Num (Num $worst 'worstGapAfterMs'))))
}
$md.Add('')
$md.Add('(A "-" split means the gap was under 250 ms, or no Java GC ended inside it.)')
$md.Add('')
$diagScenarios = @($Scenarios | Where-Object { $_ -like 'burst*' })
if ($diagScenarios.Count) {
    $md.Add('## Freeze diagnosis')
    $md.Add('')
    $md.Add('Where the long freezes sit. **UI frame work**: the longest time spent inside one frame callback; **UI peer step**: the longest single `new Peer()` / `list.Add` on the UI thread; ' +
        '**churner stall**: the same for the background thread in burst-bgpeers; **sampler stall**: the longest stall of a managed thread that does no Java interop at all ' +
        '(it only stalls if the runtime suspends managed threads). A freeze much longer than the UI frame work happened outside the frame callback''s body - in the Java->managed dispatch. ' +
        'GC generations are managed collections during the run.')
    $md.Add('')
    $md.Add('| scenario | variant | worst freeze ms | UI frame work ms | UI peer step ms | churner stall ms | sampler stall ms | GCs gen0 / gen1 / gen2 |')
    $md.Add('|---|---|---:|---:|---:|---:|---:|---|')
    foreach ($s in $diagScenarios) {
        foreach ($v in $Variants) {
            $cell = @($rows | Where-Object { $_.scenario -eq $s -and $_.variant -eq $v })
            if ($cell.Count -eq 0) { continue }
            $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} / {8} / {9} |' -f $s, $v,
                    (Format-Num (Median-Of $cell 'gapMax')), (Format-Num (Median-Of $cell 'workMax')), (Format-Num (Median-Of $cell 'peerMaxMs')),
                    (Format-Num (Median-Of $cell 'bgPeerMaxMs')), (Format-Num (Median-Of $cell 'samplerMaxGapMs')),
                    (Format-Num (Median-Of $cell 'gen0')), (Format-Num (Median-Of $cell 'gen1')), (Format-Num (Median-Of $cell 'gen2'))))
        }
    }
    $md.Add('')
}
$md.Add('## Native stacks during freezes')
$md.Add('')
$stackFiles = @(Get-ChildItem $logDir -Filter '*-stack*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $rootShell) {
    $md.Add('Not captured: the device is not rooted, and `debuggerd` needs root to dump a release app. On a rooted device (or one with `adb root`) the script dumps every thread with `debuggerd -b` while a freeze is going on.')
}
elseif ($stackFiles.Count -eq 0) {
    $md.Add('The device is rooted, but no run froze for 200 ms or more.')
}
else {
    $md.Add('Taken with `debuggerd -b` 200 ms or more into a freeze; the dump itself pauses the process briefly, so the metrics of those runs are slightly perturbed. ' +
        'Below: the main (UI) thread of the first dump per variant, and any thread inside the runtime''s bridge processing; every thread is in `logs\*-stack*.txt`. ' +
        '`libcoreclr.so` frames are symbolized when the Android NDK is installed and Microsoft''s symbol server has the build (symbols cached in `.symbols\`).')
    $md.Add('')
    foreach ($v in $Variants) {
        $pattern = '^' + [regex]::Escape($v) + '-(' + (($scenarioTable.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')-\d+-stack\d+\.txt$'
        $candidates = @($stackFiles | Where-Object { $_.Name -match $pattern })
        if ($candidates.Count -eq 0) { continue }
        # A dump can land just after a freeze ended; show the first one that caught the UI thread
        # inside the runtime, else the first one.
        $file = ($candidates | Where-Object { Test-UiInRuntime (Get-Content $_.FullName) } | Select-Object -First 1)
        if (-not $file) { $file = $candidates[0] }
        $dump = Get-Content $file.FullName
        $threads = Get-ThreadFrames $dump
        $mainHeader = $null
        $pidLine = $dump | Where-Object { $_ -match '^----- pid (\d+) ' } | Select-Object -First 1
        if ($pidLine -match '^----- pid (\d+) ') { $mainHeader = $threads.Keys | Where-Object { $_ -match (' sysTid=' + $Matches[1] + '$') } | Select-Object -First 1 }
        $symbols = Get-CoreClrSymbols $v
        $md.Add("**$v** - ``logs\$($file.Name)``" + $(if ($symbols) { ' (symbolized)' } else { ' (raw: no symbols)' }))
        $md.Add('')
        $md.Add('```')
        foreach ($header in $threads.Keys) {
            $formatted = @(Format-Frames $threads[$header] $symbols)
            $isBridge = ($formatted -join ' ') -match 'CrossReference|NullBridge|ProcessBridge|BridgeProcessing'
            if ($header -ne $mainHeader -and -not $isBridge) { continue }
            $md.Add($header + $(if ($header -eq $mainHeader) { '   <- main (UI) thread' } else { '   <- bridge processing' }))
            $formatted | Select-Object -First 25 | ForEach-Object { $md.Add('  ' + $_) }
            $md.Add('')
        }
        $md.Add('```')
        $md.Add('')
    }
}
$md.Add('')
$md.Add('## How to read it')
$md.Add('')
$md.Add('- **bridge rounds**: ART explicit collections, one per GC-bridge round (the bridge calls `java.lang.Runtime.gc()`). A managed GC only starts one when it finds dead Java peers - compare heavy with heavy-nopeers.')
$md.Add('- **UI time lost**: the sum of (frame gap - 16.7 ms) over gaps longer than 1.5 frames. **Worst freeze**: the longest gap between two frame callbacks.')
$md.Add('- **weak-read wait**: time inside the probe''s own `WeakReference.TryGetTarget` calls that took >= 1 ms. Most of the UI wait happens elsewhere - in dotnet/android''s peer lookup when Java calls into managed code - and shows up only in the frame gaps. Tens of ms here is scheduler noise (Mono shows it with no bridge rounds at all).')
$md.Add('- Raw data: `results.csv` (every metric of every run) and `logs\` (full logcat per run).')
$md | Set-Content -Encoding utf8 (Join-Path $outDir 'report.md')

Write-Host ''
Write-Step "Report: $(Join-Path $outDir 'report.md')"
