[CmdletBinding()]
param(
    [string]$ExecutablePath = 'C:\Program Files\Firefox Nightly\firefox.exe',
    [string]$Arguments = '',
    [string]$ProfilePath = '',
    [ValidateRange(1, 600)]
    [int]$StartupTimeoutSeconds = 120,
    [switch]$NoActivate,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
# Resolve the identity without requiring the file to exist while an updater is
# replacing it. Check existence only when a browser request can safely start.
$resolvedExecutable = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExecutablePath)
if (-not ('NightlyLauncherNative' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'launcher-native.cs')
}
$requestedArguments = @([NightlyLauncherNative]::Arguments(('"launcher" ' + $Arguments)) | Select-Object -Skip 1)
if ($ProfilePath) {
    $ProfilePath = (Get-Item -LiteralPath $ProfilePath -ErrorAction Stop).FullName
    if ($requestedArguments -match '^--?(profile|p)$') {
        throw 'Use either -ProfilePath or a profile argument, not both.'
    }
    $requestedArguments = @('-profile', $ProfilePath) + $requestedArguments
}

# Non-GUI commands and explicit raw profile selections keep their original
# pass-through behavior. -ProfilePath opts a GUI profile into coordination.
$isBrowser = [IO.Path]::GetFileName($resolvedExecutable) -ieq 'firefox.exe'
$isNonGui = $requestedArguments -match '^--?(headless|screenshot|help|h|version|v|backgroundtask)$'
$rawProfile = (-not $ProfilePath) -and ($requestedArguments -match '^--?(profile|p|no-remote|new-instance)$')
$managed = $isBrowser -and (-not $isNonGui) -and (-not $rawProfile)
$clock = [Diagnostics.Stopwatch]::StartNew()
$installDirectory = Split-Path -Parent $resolvedExecutable
$reportDirectory = Join-Path $PSScriptRoot '..\.local\launch'

function Get-DefaultProfile {
    $profileRoot = Join-Path $env:APPDATA 'Mozilla\Firefox'
    $installs = Join-Path $profileRoot 'installs.ini'
    if (-not (Test-Path -LiteralPath $installs)) { return '' }
    $profiles = @(& { foreach ($line in Get-Content -LiteralPath $installs) {
        if ($line -match '^Default=(.+)$') {
            $entry = $Matches[1]
            $directory = if ([IO.Path]::IsPathRooted($entry)) { [IO.Path]::GetFullPath($entry) } else { [IO.Path]::GetFullPath((Join-Path $profileRoot $entry)) }
            $compatibility = Join-Path $directory 'compatibility.ini'
            if (Test-Path -LiteralPath $compatibility) {
                $platform = @(Get-Content -LiteralPath $compatibility | Where-Object { $_ -like 'LastPlatformDir=*' })
                if ($platform.Count -eq 1 -and $platform[0].Substring(16) -ieq $installDirectory) { $directory }
            }
        }
    } } | Select-Object -Unique)
    if ($profiles.Count -eq 1) { return $profiles[0] }
    return ''
}

function Start-StartupObserver([int]$BrowserProcessId, [long]$StartUtcTicks) {
    $targetProfile = if ($ProfilePath) { $ProfilePath } else { Get-DefaultProfile }
    if (-not $targetProfile) { $receipt.startupHealth = 'profile-unresolved'; return }
    [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $remaining = [math]::Max(1, 120 - [int]([DateTime]::UtcNow - [DateTime]::new($StartUtcTicks, [DateTimeKind]::Utc)).TotalSeconds)
    $receipt.startupHealthReceiptPath = Join-Path $reportDirectory ($hash + '.' + $BrowserProcessId + '.' + $StartUtcTicks + '.health.json')
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'watch-nightly-startup.ps1'), '-BrowserProcessId', $BrowserProcessId, '-StartUtcTicks', $StartUtcTicks, '-ProfilePath', $targetProfile, '-ReceiptPath', $receipt.startupHealthReceiptPath, '-LifetimeSeconds', $remaining)) {
        $info.ArgumentList.Add([string]$argument)
    }
    $observer = [Diagnostics.Process]::Start($info)
    try { $receipt.startupObserverProcessId = $observer.Id } finally { $observer.Dispose() }
}

function Start-BrowserRequest {
    Get-Item -LiteralPath $resolvedExecutable -ErrorAction Stop | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExecutable
    $startInfo.WorkingDirectory = $installDirectory
    foreach ($argument in $requestedArguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['MOZ_REMOTE_ALLOW_SYSTEM_ACCESS'] = '1'
    $child = [Diagnostics.Process]::Start($startInfo)
    try { return $child.Id } finally { $child.Dispose() }
}

function Get-LaunchState {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='firefox.exe' OR Name='updater.exe'" -ErrorAction Stop)
    $updaters = @($processes | Where-Object {
        $_.Name -ieq 'updater.exe' -and (
            $_.ExecutablePath -ieq (Join-Path $installDirectory 'updater.exe') -or
            ($_.CommandLine -and $_.CommandLine.IndexOf(('"' + $installDirectory + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
        )
    })
    $browsers = @($processes | Where-Object {
        if ($_.ExecutablePath -ine $resolvedExecutable -or -not $_.CommandLine) { return $false }
        $parts = @([NightlyLauncherNative]::Arguments($_.CommandLine) | Select-Object -Skip 1)
        if ($parts -match '^--?(contentproc|backgroundtask)$') { return $false }
        $selectedProfile = ''
        for ($index = 0; $index -lt $parts.Count; $index++) {
            if ($parts[$index] -imatch '^--?profile$' -and $index + 1 -lt $parts.Count) {
                $selectedProfile = [IO.Path]::GetFullPath($parts[$index + 1])
            }
            if ($parts[$index] -imatch '^--?p$') { return $false }
        }
        return $selectedProfile -ieq $ProfilePath
    })
    return @{ browsers = $browsers; updating = $updaters.Count -gt 0 }
}

function Wait-ForBrowser([long]$OwnedLaunchAfterUtcTicks = 0) {
    $lastWindow = 0L
    $observing = $false
    while ($clock.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
        $state = Get-LaunchState
        if (-not $state.updating -and $state.browsers.Count) {
            if (-not $observing) {
                $anyWindow = @([NightlyLauncherNative]::BrowserWindow([int[]]@($state.browsers.ProcessId), $false))
                if ($anyWindow.Count) {
                    $process = Get-Process -Id $anyWindow[0] -ErrorAction SilentlyContinue
                    if ($process) {
                        $birth = $process.StartTime.ToUniversalTime()
                        $autoStart = @($state.browsers | Where-Object { $_.ProcessId -eq $anyWindow[0] -and [NightlyLauncherNative]::Arguments($_.CommandLine) -contains '-os-autostart' }).Count -gt 0
                        $age = ([DateTime]::UtcNow - $birth).TotalSeconds
                        if (($OwnedLaunchAfterUtcTicks -gt 0 -and $birth.Ticks -ge $OwnedLaunchAfterUtcTicks) -or ($autoStart -and $age -ge 0 -and $age -lt 120)) {
                            try { Start-StartupObserver -BrowserProcessId $process.Id -StartUtcTicks $birth.Ticks }
                            catch { $receipt.startupHealth = 'observer-unavailable' }
                        }
                        $observing = $true
                    }
                }
            }
            $window = @([NightlyLauncherNative]::ResponsiveBrowser([int[]]@($state.browsers.ProcessId)))
            if ($window.Count -and $window[1] -eq $lastWindow) { return $window }
            $lastWindow = if ($window.Count) { $window[1] } else { 0L }
        } else { $lastWindow = 0L }
        Start-Sleep -Milliseconds 250
    }
    throw 'F_STARTUP_TIMEOUT: Nightly did not become responsive. Existing browser processes and profile data were preserved.'
}

$receipt = [ordered]@{
    mode = 'started'
    processId = $null
    executablePath = $resolvedExecutable
    requestedSystemAccess = $false
    ready = $false
}
$mutex = $null
$ownsMutex = $false
try {
    if ($managed) {
        $identity = ($resolvedExecutable + '|' + $ProfilePath).ToLowerInvariant()
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).Substring(0, 24)
        $receipt.launchReceiptPath = Join-Path $reportDirectory ($hash + '.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $mutex = [Threading.Mutex]::new($false, ('Local\FirefoxNightlyLauncher-' + $hash))
        try { $ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds($StartupTimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'F_LAUNCH_BUSY: Another Nightly launch is still pending.' }
        $state = Get-LaunchState
        while ($state.updating -and $clock.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
            Start-Sleep -Milliseconds 250
            $state = Get-LaunchState
        }
        if ($state.updating) { throw 'F_UPDATE_BUSY: Nightly is still being updated; no new browser was started.' }
        if ($state.browsers.Count) {
            $window = Wait-ForBrowser
            $receipt.mode = 'reused'
            $receipt.processId = $window[0]
            # An existing process cannot acquire the startup-only environment.
            if ($Arguments.Trim()) {
                if ($requestedArguments -match '^--?(no-remote|new-instance)$') { throw 'F_PROFILE_IN_USE: The selected profile already has a running browser.' }
                $receipt.requestProcessId = Start-BrowserRequest
                $receipt.requestedSystemAccess = $true
            }
        } else {
            $ownedLaunchAfter = [DateTime]::UtcNow.Ticks
            $receipt.requestProcessId = Start-BrowserRequest
            $receipt.requestedSystemAccess = $true
            $window = Wait-ForBrowser -OwnedLaunchAfterUtcTicks $ownedLaunchAfter
            $receipt.processId = $window[0]
        }
        $receipt.ready = $true
        if (-not $NoActivate) { $receipt.activated = [NightlyLauncherNative]::Activate($window[1]) }
    } else {
        $receipt.processId = Start-BrowserRequest
        $receipt.requestedSystemAccess = $true
    }
    if ($PassThru) { [pscustomobject]$receipt | ConvertTo-Json -Compress }
} catch {
    $receipt.error = $_.Exception.Message
    throw
} finally {
    if ($managed) {
        $receipt.elapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
        $receipt.recordedAt = [DateTime]::UtcNow.ToString('o')
        try {
            [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
            $destination = $receipt.launchReceiptPath
            $temporary = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporary, ([pscustomobject]$receipt | ConvertTo-Json -Depth 3))
            [IO.File]::Move($temporary, $destination, $true)
        } catch { Write-Warning 'Could not save the Nightly launch receipt.' }
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
