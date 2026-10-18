param(
    [string]$ExecutablePath='C:\Program Files\Firefox Nightly\firefox.exe',
    [ValidateRange(1,65535)][int]$Port=9222,
    [string]$Hwnd=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -Path (Join-Path $PSScriptRoot 'desktop-guard.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'consent-focus.cs')
. (Join-Path $PSScriptRoot 'desktop-policy.ps1')
$script:baseline=$null
$script:guardBaseline=$null
$script:guardLocked=$false
$script:preflightRebases=0
$script:lastGuardFailure=$null
$script:focusPolicy=$null
$script:consentFocusStart=0
$script:browserPid=0
$script:browserCreated=$null
$script:consentArmed=$false
$script:consentInvoked=$false
$script:consentSeen=$false
$script:consentDialogHandle=0
$script:lastNativeAction=$null
$script:lastInvocationIssued=$false
$script:lastControlState=$null
$script:consentMessage='An application wants to control this browser session. It can read the content of your tabs, access your saved data, and navigate to any website. Only allow this if you started the connection yourself and you trust both the application and this computer.'

function Find-ById($Root,[string]$Id,[switch]$Children) {
    $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)
    $scope=if($Children){[System.Windows.Automation.TreeScope]::Children}else{[System.Windows.Automation.TreeScope]::Descendants}
    return @($Root.FindAll($scope,$condition))
}
function Get-Roots {
    $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$script:browserPid)
    return @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,$condition))
}
function Get-BrowserRoots {
    $roots=@(Get-Roots | Where-Object { $_.Current.ClassName -eq 'MozillaWindowClass' -and @(Find-ById $_ 'TabsToolbar' -Children).Count -eq 1 })
    # Modal consent can remove its owner from UIA's desktop-children enumeration.
    # Read the already verified HWND directly; this does not activate the window.
    $knownSnapshot=if($script:guardBaseline){$script:guardBaseline}else{$script:baseline}
    if($knownSnapshot) {
        foreach($window in $knownSnapshot.windows) {
            $handle=[IntPtr][long]$window.hwnd
            if(@($roots | Where-Object { [long]$_.Current.NativeWindowHandle -eq $handle.ToInt64() }).Count -gt 0 -or -not [NightlyDesktop]::IsWindow($handle)) { continue }
            $ownerPid=[uint32]0
            $null=[NightlyDesktop]::GetWindowThreadProcessId($handle,[ref]$ownerPid)
            if($ownerPid -ne $script:browserPid) { continue }
            $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if($root.Current.ProcessId -eq $script:browserPid -and $root.Current.ClassName -eq 'MozillaWindowClass' -and @(Find-ById $root 'TabsToolbar' -Children).Count -eq 1) { $roots+=@($root) }
        }
    }
    return $roots
}
function Get-ProcessIdentity {
    $process=Get-CimInstance Win32_Process -Filter "ProcessId = $script:browserPid"
    if(-not $process -or $process.ExecutablePath -ine $ExecutablePath -or $process.CreationDate.ToUniversalTime().ToString('o') -ne $script:browserCreated) { throw 'F_BROWSER_CHANGED' }
    if($process.CommandLine -match '(?i)--?(marionette|remote-debugging-port)(?:[=\s"]|$)') { throw 'F_AUTOMATION_STARTUP' }
    return $process
}
function Get-Snapshot {
    $null=Get-ProcessIdentity
    $windows=@()
    foreach($root in Get-BrowserRoots) {
        $handle=[IntPtr]$root.Current.NativeWindowHandle
        $rect=[NightlyDesktop+Rect]::new()
        if(-not [NightlyDesktop]::GetWindowRect($handle,[ref]$rect)) { throw 'F_OBSERVER_UNAVAILABLE' }
        $toolbar=@(Find-ById $root 'TabsToolbar' -Children)
        $strip=@(Find-ById $toolbar[0] 'tabbrowser-tabs')
        if($strip.Count -ne 1) { throw 'F_OBSERVER_UNAVAILABLE' }
        $tabCondition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::TabItem)
        $tabs=@(foreach($tab in $strip[0].FindAll([System.Windows.Automation.TreeScope]::Descendants,$tabCondition)) {
            $isSelected=([System.Windows.Automation.SelectionItemPattern]$tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Current.IsSelected
            $runtimeId=''
            if($isSelected) { try { $runtimeId=$tab.GetRuntimeId() -join ':' } catch { } }
            @{automationId=[string]$tab.Current.AutomationId;runtimeId=$runtimeId;selected=$isSelected}
        })
        $selection=Get-TabSelection $tabs
        $windows+=@{ hwnd=$handle.ToInt64().ToString(); minimized=[NightlyDesktop]::IsIconic($handle); bounds=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom); selectedTab=$selection.runtimeId; selectedTabKey=$selection.key; selectedTabIdentityKind=$selection.kind; selectedTabPosition=$selection.position }
    }
    if($windows.Count -eq 0) { throw 'F_BROWSER_NOT_FOUND' }
    return @{ foreground=[NightlyDesktop]::GetForegroundWindow().ToInt64().ToString(); clipboardSequence=[NightlyDesktop]::GetClipboardSequenceNumber(); windows=@($windows | Sort-Object hwnd) }
}
function Get-GuardReport {
    $after=Get-Snapshot
    $events=@([NightlyDesktop]::ForegroundEvents())
    $baseline=$script:baseline
    $comparison=Compare-DesktopSnapshot $script:guardBaseline $after
    $targetWindows=@($after.windows | ForEach-Object { [long]$_.hwnd }) + @($events | Where-Object { $_.Process -eq $script:browserPid } | ForEach-Object Window)
    $foregroundOwner=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr][long]$after.foreground,[ref]$foregroundOwner)
    if($foregroundOwner -eq $script:browserPid) { $targetWindows+=@([long]$after.foreground) }
    return @{
        foregroundStable=($after.foreground -eq $baseline.foreground -and @($events | Where-Object { $_.Window.ToString() -ne $baseline.foreground }).Count -eq 0)
        clipboardStable=($after.clipboardSequence -eq $baseline.clipboardSequence)
        windowsStable=$comparison.windowsStable
        windowIdentityStable=$comparison.windowIdentityStable
        windowGeometryStable=$comparison.windowGeometryStable
        selectedTabsStable=$comparison.selectedTabsStable
        tabProviderIdentityStable=$comparison.tabProviderIdentityStable
        desktopChanges=$comparison.reasons
        initialWindowsStable=(Compare-DesktopSnapshot $baseline $after).windowsStable
        clipboardPolicy='observe-only'
        guardLocked=$script:guardLocked
        preflightRebases=$script:preflightRebases
        lastFailure=$script:lastGuardFailure
        foregroundWithinConsentPolicy=$script:focusPolicy.AllowsConsentOnly([long[]]@($events | ForEach-Object Window),[long]$after.foreground)
        foregroundWithinControlPolicy=$script:focusPolicy.Allows([long[]]@($events | ForEach-Object Window),[long]$after.foreground)
        browserForegroundWithinControlPolicy=$script:focusPolicy.AllowsForWindows([long[]]@($events | ForEach-Object Window),[long]$after.foreground,[long[]]$targetWindows)
        consentFocusActive=($script:focusPolicy.Active -and -not $script:focusPolicy.ServiceStartActive)
        serviceStartFocusActive=$script:focusPolicy.ServiceStartActive
        consentActivationDefault=$true
        serviceStartActivationDefault=$true
        mainWindowActivationAllowed=$script:focusPolicy.ServiceStartActive
        foregroundEventCount=$events.Count
        nightlyForegroundEventCount=@($events | Where-Object { $_.Process -eq $script:browserPid }).Count
        lastNativeAction=$script:lastNativeAction
        lastInvocationIssued=$script:lastInvocationIssued
        lastControlState=$script:lastControlState
    }
}
function Assert-Desktop([switch]$PassThru) {
    $report=Get-GuardReport
    if(-not $report.windowsStable -or -not $report.browserForegroundWithinControlPolicy) {
        $reasons=@($report.desktopChanges)
        if(-not $report.browserForegroundWithinControlPolicy) { $reasons+='browser-focus' }
        $script:lastGuardFailure=@{reasons=$reasons;windowIdentityStable=$report.windowIdentityStable;windowGeometryStable=$report.windowGeometryStable;selectedTabsStable=$report.selectedTabsStable;clipboardStable=$report.clipboardStable;browserForegroundWithinControlPolicy=$report.browserForegroundWithinControlPolicy}
        throw 'F_DESKTOP_CHANGED'
    }
    if($PassThru) { return $report }
}
function Prepare-Desktop {
    if($script:guardLocked) { return }
    # Settle only before any owned UI action or connection. Never retry tasks,
    # replay a native invocation, or erase an already protected interval.
    $previous=Get-Snapshot
    for($attempt=0;$attempt -lt 3;$attempt++) {
        Start-Sleep -Milliseconds 50
        $current=Get-Snapshot
        $comparison=Compare-DesktopSnapshot $previous $current
        if($comparison.windowsStable) {
            if(-not (Compare-DesktopSnapshot $script:guardBaseline $current).windowsStable) { $script:preflightRebases++ }
            $script:guardBaseline=$current
            $script:focusPolicy.SetCheckpoint(@([NightlyDesktop]::ForegroundEvents()).Count,[long]$current.foreground)
            $script:guardLocked=$true
            return
        }
        $previous=$current
    }
    $script:lastGuardFailure=@{reasons=@('preparation-unstable')+@($comparison.reasons)}
    throw 'F_DESKTOP_UNSTABLE'
}
function Begin-ConsentFocus($Dialog,[int]$EventIndex) {
    if($Dialog.Current.ClassName -ne 'MozillaDialogClass' -or $Dialog.Current.AutomationId -ne 'commonDialogWindow' -or $Dialog.Current.ProcessId -ne $script:browserPid) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    if(-not $script:focusPolicy.Active) {
        $script:focusPolicy.Begin($EventIndex,[long]$Dialog.Current.NativeWindowHandle,[long](Get-TargetRoot).Current.NativeWindowHandle)
    }
}
function Finish-ConsentFocus {
    if($script:focusPolicy.Active) {
        if($script:consentDialogHandle -and [NightlyDesktop]::IsWindow([IntPtr]$script:consentDialogHandle)) { throw 'F_CONSENT_NOT_CLOSED' }
        $script:focusPolicy.Complete(@([NightlyDesktop]::ForegroundEvents()).Count,[NightlyDesktop]::GetForegroundWindow().ToInt64())
    }
    Assert-Desktop
}
function Get-TargetRoot {
    $roots=@(Get-BrowserRoots)
    if($Hwnd) {
        if($Hwnd -notmatch '^0x[0-9a-fA-F]+$') { throw 'F_INVALID_HWND' }
        $numeric=[Convert]::ToInt64($Hwnd.Substring(2),16)
        $roots=@($roots | Where-Object { [long]$_.Current.NativeWindowHandle -eq $numeric })
    }
    if($roots.Count -ne 1) { throw 'F_WINDOW_AMBIGUOUS' }
    return $roots[0]
}
function Get-ToolbarButton($Root) {
    $navs=@(Find-ById $Root 'nav-bar' -Children)
    if($navs.Count -ne 1) { throw 'F_NATIVE_UNAVAILABLE' }
    $buttons=@(Find-ById $navs[0] 'remote-control-toolbar-button')
    if($buttons.Count -ne 1) { throw 'F_REMOTE_CONTROL_BUTTON_UNAVAILABLE' }
    return $buttons[0]
}
function Get-Endpoint([int]$TargetPort=$Port) {
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $TargetPort -ErrorAction SilentlyContinue)
    if($listeners.Count -eq 0) { return @{ listening=$false; verified=$false } }
    $owners=@($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    $verified=($owners.Count -eq 1 -and $owners[0] -eq $script:browserPid -and @($listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1','::1') }).Count -eq 0)
    return @{ listening=$true; verified=$verified; created=@($listeners | ForEach-Object { $_.CreationTime.ToUniversalTime().Ticks.ToString() } | Sort-Object) }
}
function Get-Status {
    $null=Get-ProcessIdentity
    $root=Get-TargetRoot
    $button=$null
    try { $button=Get-ToolbarButton $root } catch {}
    return @{
        browser=@{ processId=$script:browserPid; created=$script:browserCreated; executablePath=$ExecutablePath; version=(Get-Item -LiteralPath $ExecutablePath).VersionInfo.ProductVersion }
        endpoint=(Get-Endpoint); port=$Port
        window=@{ hwnd=('0x{0:X}' -f $root.Current.NativeWindowHandle); minimized=[NightlyDesktop]::IsIconic([IntPtr]$root.Current.NativeWindowHandle) }
        toolbarAvailable=($null -ne $button)
        consentAutomationAvailable=$true
        toolbarRunning=($null -ne $button -and $button.Current.Name -ceq 'Remote control (on)')
        guard=(Get-GuardReport)
    }
}
function Invoke-Native($Element,[switch]$WaitForEnabled) {
    $script:lastInvocationIssued=$false
    Assert-Desktop
    $current=$Element.Current
    $script:lastControlState=@{action=$script:lastNativeAction;enabled=$current.IsEnabled;offscreen=$current.IsOffscreen;invokeAvailable=$null}
    if($current.IsOffscreen) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    if(-not $current.IsEnabled) {
        if($WaitForEnabled) { return $false }
        throw 'F_BACKGROUND_CONTROL_UNAVAILABLE'
    }
    $pattern=$null
    $script:lastControlState.invokeAvailable=$Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)
    if(-not $script:lastControlState.invokeAvailable) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    $script:lastInvocationIssued=$true
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
    Start-Sleep -Milliseconds 120
    Assert-Desktop
    if($WaitForEnabled) { return $true }
}
function Set-Power([bool]$Enabled) {
    Prepare-Desktop
    $root=Get-TargetRoot
    if($script:focusPolicy.Active) { throw 'F_CONSENT_NOT_CLOSED' }
    if([NightlyDesktop]::IsIconic([IntPtr]$root.Current.NativeWindowHandle)) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    # Starting Remote Control is pre-authorized, including activation caused by
    # its native controls. Stopping still requires background-safe controls.
    if(-not $Enabled -and [NightlyDesktop]::GetForegroundWindow().ToInt64() -ne [long]$root.Current.NativeWindowHandle) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    Assert-Desktop
    $button=Get-ToolbarButton $root
    $expected=if($Enabled){'Remote control'}else{'Remote control (on)'}
    if($button.Current.Name -cne $expected) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
    if($Enabled) { $script:focusPolicy.BeginServiceStart(@([NightlyDesktop]::ForegroundEvents()).Count,[long]$root.Current.NativeWindowHandle) }
    try {
        $toggle=Find-PowerToggle
        if(-not $toggle) {
            $script:lastNativeAction='open-remote-panel'
            Invoke-Native $button
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        $toggle=$null
        do {
            Assert-Desktop
            # Only native top-level popup children are searched, never web documents.
            $toggle=Find-PowerToggle
            if(-not $toggle) { Start-Sleep -Milliseconds 100 }
        } while(-not $toggle -and [DateTime]::UtcNow -lt $deadline)
        if(-not $toggle) { throw 'F_BACKGROUND_PANEL_UNAVAILABLE' }
        $label=if($Enabled){'Turn on'}else{'Turn off'}
        if($toggle.Current.Name -cne $label) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
        $script:lastNativeAction=if($Enabled){'turn-on'}else{'turn-off'}
        Invoke-Native $toggle
        if(Find-PowerToggle) {
            $script:lastNativeAction='close-remote-panel'
            Invoke-Native (Get-ToolbarButton (Get-TargetRoot))
        }
        return @{ requested=$Enabled }
    } finally {
        if($Enabled -and $script:focusPolicy.ServiceStartActive) {
            $script:focusPolicy.Complete(@([NightlyDesktop]::ForegroundEvents()).Count,[NightlyDesktop]::GetForegroundWindow().ToInt64())
            Assert-Desktop
        }
    }
}
function Find-PowerToggle {
    $found=@()
    foreach($nativeRoot in Get-Roots) {
        $containers=@($nativeRoot)+@($nativeRoot.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition))
        foreach($child in $containers) {
            if($child.Current.AutomationId -notin @('customizationui-widget-panel','remote-control-panel') -and $child.Current.ControlType -ne [System.Windows.Automation.ControlType]::Menu) { continue }
            $found+=@(Find-ById $child 'remote-control-panel-toggle-button' | Where-Object { -not $_.Current.IsOffscreen })
        }
    }
    if($found.Count -gt 1) { throw 'F_NATIVE_AMBIGUOUS' }
    if($found.Count -eq 1) { return $found[0] }
    return $null
}
function Get-ConsentDialogs {
    $roots=@(Get-Roots)
    $candidates=@($roots)
    # Restored Nightly exposes owned native dialogs as direct chrome children;
    # minimized Nightly exposes them as desktop roots. Never search web content.
    foreach($root in $roots) {
        if($root.Current.ClassName -eq 'MozillaWindowClass' -and @(Find-ById $root 'TabsToolbar' -Children).Count -eq 1) {
            $candidates+=@($root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition) | Where-Object {
                $_.Current.ClassName -eq 'MozillaDialogClass' -and $_.Current.AutomationId -eq 'commonDialogWindow'
            })
        }
    }
    return @($candidates | Where-Object {
        $_.Current.ClassName -in @('MozillaWindowClass','MozillaDialogClass') -and
        $_.Current.Name -match '^Allow remote control\?(?:\s*-.*)?$' -and
        @(Find-ById $_ 'TabsToolbar' -Children).Count -eq 0
    } | Sort-Object { $_.Current.NativeWindowHandle } -Unique)
}
function Poll-Consent {
    if(-not $script:consentArmed) { throw 'F_CONSENT_NOT_ARMED' }
    $dialogs=@(Get-ConsentDialogs)
    if($dialogs.Count -gt 1) { throw 'F_CONSENT_AMBIGUOUS' }
    if($dialogs.Count -eq 0) {
        if($script:consentInvoked) { Finish-ConsentFocus } else { Assert-Desktop }
        return @{ seen=$script:consentSeen; invoked=$script:consentInvoked; closed=$script:consentInvoked }
    }
    if($script:consentInvoked) { Assert-Desktop; return @{ seen=$true; invoked=$true; closed=$false } }
    $dialog=$dialogs[0]
    if($dialog.Current.ClassName -ne 'MozillaDialogClass' -or $dialog.Current.AutomationId -ne 'commonDialogWindow') { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $elements=@($dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))
    $allows=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq 'Allow' })
    $denies=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq 'Deny' })
    $checkboxes=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -and $_.Current.Name -ceq 'Remember my decision until the browser exits' })
    $messageMatches=@(Find-ById $dialog 'infoBody' | Where-Object { $_.Current.Name -ceq $script:consentMessage })
    if($allows.Count -ne 1 -or $denies.Count -ne 1 -or $checkboxes.Count -ne 1 -or $messageMatches.Count -ne 1) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $script:consentDialogHandle=$dialog.Current.NativeWindowHandle
    $checkbox=[System.Windows.Automation.TogglePattern]$checkboxes[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if($checkbox.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'F_CONSENT_SCOPE_CHANGED' }
    $script:consentSeen=$true
    Begin-ConsentFocus $dialog $script:consentFocusStart
    Assert-Desktop
    $script:lastNativeAction='allow-own-consent'
    # Read readiness at the invocation boundary: it can change after discovery.
    # Only the verified current consent waits; ordinary native actions still fail.
    if(-not (Invoke-Native $allows[0] -WaitForEnabled)) {
        return @{ seen=$true; invoked=$false; closed=$false; waitingFor='allow-enabled' }
    }
    $script:consentInvoked=$true
    $closed=(-not [NightlyDesktop]::IsWindow([IntPtr]$script:consentDialogHandle))
    if($closed) { Finish-ConsentFocus }
    return @{ seen=$true; invoked=$true; closed=$closed }
}
function Cancel-Consent {
    if(-not $script:consentArmed -or -not $script:consentDialogHandle -or $script:consentInvoked) { return @{ cancelled=$false } }
    Assert-Desktop
    $dialogs=@(Get-ConsentDialogs | Where-Object { $_.Current.NativeWindowHandle -eq $script:consentDialogHandle -and $_.Current.AutomationId -eq 'commonDialogWindow' })
    if($dialogs.Count -eq 0) { return @{ cancelled=$false } }
    if($dialogs.Count -ne 1) { throw 'F_CONSENT_AMBIGUOUS' }
    $condition=[System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Button),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,'Deny')
    )
    $buttons=@($dialogs[0].FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition))
    if($buttons.Count -ne 1) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $handle=[IntPtr]$dialogs[0].Current.NativeWindowHandle
    $script:lastNativeAction='close-own-consent'
    [NightlyDesktop]::CloseResetConsent($handle)
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    while([NightlyDesktop]::IsWindow($handle) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if([NightlyDesktop]::IsWindow($handle)) { throw 'F_CONSENT_CLOSE_FAILED' }
    Finish-ConsentFocus
    return @{ cancelled=$true }
}
function Close-ResetConsent {
    # Only explicit session reset calls this, and only Firefox's native remote
    # connection consent is eligible. WM_CLOSE denies it without mouse/focus.
    Prepare-Desktop
    Assert-Desktop
    $dialogs=@(Get-ConsentDialogs)
    if($dialogs.Count -gt 1) { throw 'F_CONSENT_AMBIGUOUS' }
    if($dialogs.Count -eq 0) { return @{ closed=$false } }
    $dialog=$dialogs[0]
    if($dialog.Current.ClassName -ne 'MozillaDialogClass' -or $dialog.Current.AutomationId -ne 'commonDialogWindow') { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $messages=@(Find-ById $dialog 'infoBody' | Where-Object { $_.Current.Name -ceq $script:consentMessage })
    $checks=@(Find-ById $dialog 'checkbox' | Where-Object { $_.Current.Name -ceq 'Remember my decision until the browser exits' })
    if($messages.Count -ne 1 -or $checks.Count -ne 1) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $checkbox=[System.Windows.Automation.TogglePattern]$checks[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if($checkbox.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'F_CONSENT_SCOPE_CHANGED' }
    $handle=[IntPtr]$dialog.Current.NativeWindowHandle
    $script:consentDialogHandle=$handle.ToInt64()
    Begin-ConsentFocus $dialog (@([NightlyDesktop]::ForegroundEvents()).Count)
    $script:lastNativeAction='close-reset-consent'
    [NightlyDesktop]::CloseResetConsent($handle)
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    while([NightlyDesktop]::IsWindow($handle) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if([NightlyDesktop]::IsWindow($handle)) { throw 'F_CONSENT_CLOSE_FAILED' }
    Finish-ConsentFocus
    return @{ closed=$true }
}

try {
    $candidates=@(Get-CimInstance Win32_Process -Filter "Name = 'firefox.exe'" | Where-Object { $_.ExecutablePath -ieq $ExecutablePath -and $_.CommandLine -notmatch '(?i)-contentproc' })
    if($candidates.Count -ne 1) { throw 'F_BROWSER_NOT_UNIQUE' }
    $script:browserPid=[int]$candidates[0].ProcessId
    $script:browserCreated=$candidates[0].CreationDate.ToUniversalTime().ToString('o')
    [NightlyDesktop]::Start()
    $script:baseline=Get-Snapshot
    $script:guardBaseline=$script:baseline
    $script:focusPolicy=[ConsentFocusPolicy]::new([long]$script:baseline.foreground)
    @{ ready=$true } | ConvertTo-Json -Compress
    [Console]::Out.Flush()
    while($null -ne ($line=[Console]::In.ReadLine())) {
        $request=$null
        try {
            $request=$line | ConvertFrom-Json
            $data=switch($request.op) {
                'status' { Get-Status }
                'marionetteEndpoint' { Get-Endpoint 2828 }
                'closeResetConsent' { Close-ResetConsent }
                'power' { Set-Power ([bool]$request.enabled) }
                'beginConsent' {
                    Prepare-Desktop
                    Assert-Desktop
                    if(@(Get-ConsentDialogs).Count -gt 0) { throw 'F_CONSENT_ALREADY_PRESENT' }
                    $script:consentArmed=$true; $script:consentInvoked=$false; $script:consentSeen=$false; $script:consentDialogHandle=0
                    $script:consentFocusStart=@([NightlyDesktop]::ForegroundEvents()).Count
                    @{ armed=$true }
                }
                'pollConsent' { Poll-Consent }
                'cancelConsent' { Cancel-Consent }
                'endConsent' { Finish-ConsentFocus; $script:consentArmed=$false; @{ ended=$true } }
                'assert' { Prepare-Desktop; Assert-Desktop -PassThru }
                'report' { Get-GuardReport }
                default { throw 'F_INVALID_NATIVE_OPERATION' }
            }
            @{ id=$request.id; ok=$true; data=$data } | ConvertTo-Json -Compress -Depth 10
        } catch {
            $code=if($_.Exception.Message -match '^F_[A-Z_]+$'){$_.Exception.Message}else{'F_NATIVE_UNAVAILABLE'}
            @{ id=$(if($request){$request.id}else{0}); ok=$false; error=$code } | ConvertTo-Json -Compress
        }
        [Console]::Out.Flush()
    }
} catch {
    $code=if($_.Exception.Message -match '^F_[A-Z_]+$'){$_.Exception.Message}else{'F_NATIVE_UNAVAILABLE'}
    @{ ready=$false; error=$code } | ConvertTo-Json -Compress
    exit 1
} finally {
    [NightlyDesktop]::Stop()
}
