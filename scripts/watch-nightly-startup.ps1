[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$BrowserProcessId,
    [Parameter(Mandatory)][long]$StartUtcTicks,
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [ValidateRange(1, 180)][int]$LifetimeSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ownership = [Threading.Mutex]::new($false, ('Local\NightlyStartupHealth-' + $BrowserProcessId + '-' + $StartUtcTicks))
try { $ownsObserver = $ownership.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $ownsObserver = $true }
if (-not $ownsObserver) { $ownership.Dispose(); exit 0 }
try {
    if (Test-Path -LiteralPath $ReceiptPath) {
        $previous = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
        if ($previous.processId -eq $BrowserProcessId -and $previous.startUtcTicks -eq [string]$StartUtcTicks -and $previous.status -in @('recovered', 'no-background-io-thread', 'recovery-did-not-resolve-hang', 'observer-error')) {
            $ownership.ReleaseMutex()
            $ownership.Dispose()
            exit 0
        }
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'launcher-native.cs')
} catch {
    $ownership.ReleaseMutex()
    $ownership.Dispose()
    throw
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$deadline = [DateTime]::new($StartUtcTicks, [DateTimeKind]::Utc).AddSeconds(120)
$report = [ordered]@{ processId = $BrowserProcessId; startUtcTicks = [string]$StartUtcTicks; status = 'observing'; recoveredThreads = @() }
$lease = $null
$hangSince = $null
$recoverySince = $null
$attempted = $false
function Save-StartupHealth {
    $report.elapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
    $temporary = $ReceiptPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ([pscustomobject]$report | ConvertTo-Json -Depth 4))
    [IO.File]::Move($temporary, $ReceiptPath, $true)
}
try {
    while ($clock.Elapsed.TotalSeconds -lt $LifetimeSeconds -and [DateTime]::UtcNow -lt $deadline -and [NightlyLauncherNative]::MatchesProcess($BrowserProcessId, $StartUtcTicks)) {
        $window = @([NightlyLauncherNative]::BrowserWindow(@($BrowserProcessId), $false))
        $responsive = @([NightlyLauncherNative]::ResponsiveBrowser(@($BrowserProcessId))).Count -gt 0
        if ($responsive) {
            $hangSince = $null
            if ($lease) {
                $lease.Dispose()
                $lease = $null
                $report.status = 'recovered'
                break
            }
        } elseif ($window.Count -and $null -eq $hangSince) { $hangSince = $clock.Elapsed.TotalSeconds }

        if (-not $attempted -and $null -ne $hangSince -and $clock.Elapsed.TotalSeconds - $hangSince -ge 2) {
            $hangFile = Get-Item -LiteralPath (Join-Path $ProfilePath 'last_permahang.bin') -ErrorAction SilentlyContinue
            if ($hangFile -and $hangFile.LastWriteTimeUtc.Ticks -lt $StartUtcTicks -and $report.status -eq 'observing') {
                $report.status = 'stale-hang-record'
                Save-StartupHealth
            }
            if ($hangFile -and $hangFile.LastWriteTimeUtc.Ticks -ge $StartUtcTicks) {
                try {
                    $hangData = [IO.File]::ReadAllBytes($hangFile.FullName)
                    $known = [NightlyLauncherNative]::IsStartupCacheHang($hangData)
                }
                catch [IO.IOException] { $known = $false } # The writer may not have finished the record yet.
                if ($known) {
                    $attempted = $true
                    # Gecko can remove its record after the hang ends. Preserve
                    # the matched bytes before attempting recovery.
                    try {
                        $report.hangRecordPath = $ReceiptPath + '.bhr.bin'
                        [IO.File]::WriteAllBytes($report.hangRecordPath, $hangData)
                    } catch [IO.IOException] { $report.hangRecordPath = 'save-failed' }
                    $lease = [NightlyLauncherNative]::BeginCacheIoRecovery($BrowserProcessId, $StartUtcTicks)
                    $report.recoveredThreads = [int[]]$lease.Threads
                    $report.status = if ($lease.Threads.Count) { 'recovery-pending' } else { 'no-background-io-thread' }
                    $recoverySince = $clock.Elapsed.TotalSeconds
                    if (-not $lease.Threads.Count) { break }
                }
            }
        }
        if ($lease -and $clock.Elapsed.TotalSeconds - $recoverySince -ge 10) {
            $report.status = 'recovery-did-not-resolve-hang'
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($report.status -eq 'observing') { $report.status = if ($null -eq $hangSince) { 'no-observed-hang' } else { 'unrecognized-hang' } }
} catch {
    $report.status = 'observer-error'
    $report.error = $_.Exception.GetType().Name
} finally {
    try {
        if ($lease) { $lease.Dispose() }
        Save-StartupHealth
    } finally {
        $ownership.ReleaseMutex()
        $ownership.Dispose()
    }
}
