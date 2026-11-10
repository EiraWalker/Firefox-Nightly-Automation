param(
    [string]$ExecutablePath='C:\Program Files\Firefox Nightly\firefox.exe',
    [ValidateRange(1,65535)][int]$Port=9222,
    [string]$Hwnd='',
    [switch]$WorkspaceGuard
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -Path (Join-Path $PSScriptRoot 'desktop-guard.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'consent-focus.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'window-placement.cs')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
// The property dies with the window; PID and process creation time alone
// cannot distinguish a destroyed window from an HWND reused in that process.
public static class NightlyWorkspaceWindow {
    delegate bool EnumWindow(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback, IntPtr state);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder name, int length);
    public static string ClassName(IntPtr hwnd) { var name=new System.Text.StringBuilder(256); return GetClassName(hwnd,name,name.Capacity)>0 ? name.ToString() : ""; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetProp(IntPtr hwnd, string key, IntPtr value);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetProp(IntPtr hwnd, string key);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr RemoveProp(IntPtr hwnd, string key);
    public static long[] TopLevelWindows() {
        var windows=new List<long>();
        if (!EnumWindows((hwnd,state) => { windows.Add(hwnd.ToInt64()); return true; },IntPtr.Zero)) throw new Exception("F_OBSERVER_UNAVAILABLE");
        return windows.ToArray();
    }
    public static void Claim(IntPtr hwnd, string cookie) {
        if (!SetProp(hwnd,cookie,new IntPtr(1))) throw new Exception("F_WORKSPACE_UNAVAILABLE");
    }
    public static bool Owns(IntPtr hwnd, string cookie) { return GetProp(hwnd,cookie)==new IntPtr(1); }
    public static void Release(IntPtr hwnd, string cookie) { if (Owns(hwnd,cookie)) RemoveProp(hwnd,cookie); }
}
'@
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
$script:consentInvocationAttempted=$false
$script:consentSeen=$false
$script:consentDialogHandle=0
$script:lastNativeAction=$null
$script:lastInvocationIssued=$false
$script:lastInvokeReturned=$false
$script:nativePhase='initialize'
$script:lastNativeFailure=$null
$script:lastControlState=$null
$script:lastServiceWindowPreparation=$null
$script:activeServiceStartPreparation=$null
$script:lastConsentWindowPreparation=$null
$script:activeConsentWindowPreparation=$null
$script:workspaceGuardEnabled=[bool]$WorkspaceGuard
$script:workspace=$null
$script:workspaceHistory=@()
$script:workspaceFocusIntervals=@()
$script:originalTargetHwnd=0
$script:originalTargetRoot=$null
$script:consentMessage='An application wants to control this browser session. It can read the content of your tabs, access your saved data, and navigate to any website. Only allow this if you started the connection yourself and you trust both the application and this computer.'

function Get-NativeFailure($Failure) {
    # Never serialize Message, PositionMessage, command text or raw stack paths:
    # provider exceptions can contain private titles, URLs and page content.
    $types=@(); $cause=$Failure.Exception
    while($null -ne $cause -and $types.Count -lt 8) {
        $types+=@($cause.GetType().FullName)
        $cause=$cause.InnerException
    }
    $frames=@(foreach($frame in ($Failure.ScriptStackTrace -split '\r?\n')) {
        if($frame -match '^at ([A-Za-z][A-Za-z0-9-]*), .*: line ([0-9]+)$') {
            @{function=$Matches[1];line=[int]$Matches[2]}
        }
    })
    return @{phase=$script:nativePhase;action=$script:lastNativeAction;invocationIssued=[bool]$script:lastInvocationIssued;invokeReturned=[bool]$script:lastInvokeReturned;exceptionTypes=$types;hresult=$Failure.Exception.GetBaseException().HResult;frames=$frames}
}
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
    if(Test-WorkspaceGuard) {
        # UIA failure in another user window cannot block the verified workspace.
        # Unavailable observations are retained by Get-Snapshot's HWND walk.
        foreach($handle in [NightlyWorkspaceWindow]::TopLevelWindows()) {
            $ownerPid=[uint32]0; $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr]$handle,[ref]$ownerPid)
            if($ownerPid -ne $script:browserPid -or [NightlyWorkspaceWindow]::ClassName([IntPtr]$handle) -ne 'MozillaWindowClass') { continue }
            try {
                $root=Get-RootByHandle $handle
                if($root.Current.ProcessId -eq $script:browserPid -and $root.Current.ClassName -eq 'MozillaWindowClass' -and @(Find-ById $root 'TabsToolbar' -Children).Count -eq 1) { $root }
            } catch { }
        }
        return
    }
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
function Get-RootByHandle([long]$Handle) {
    return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Handle)
}
function Get-WindowSnapshot([long]$Handle,$Root=$null,[switch]$AllowUnavailable) {
    $window=@{hwnd=$Handle.ToString();minimized=[NightlyDesktop]::IsIconic([IntPtr]$Handle);observationAvailable=$true}
    try {
        $rect=[NightlyDesktop+Rect]::new()
        if(-not [NightlyDesktop]::GetWindowRect([IntPtr]$Handle,[ref]$rect)) { throw 'F_OBSERVER_UNAVAILABLE' }
        $window.bounds=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
        $placement=[NightlyWindowPlacement]::Read([IntPtr]$Handle)
        if($placement.Minimized -ne $window.minimized) { throw 'F_OBSERVER_UNAVAILABLE' }
        $window.normalBounds=$placement.NormalBounds
        $window.restoredState=$placement.RestoredState
        if(-not $Root) { $Root=Get-RootByHandle $Handle }
        if($Root.Current.ProcessId -ne $script:browserPid -or $Root.Current.ClassName -ne 'MozillaWindowClass' -or [long]$Root.Current.NativeWindowHandle -ne $Handle) { throw 'F_OBSERVER_UNAVAILABLE' }
        $toolbar=@(Find-ById $root 'TabsToolbar' -Children)
        if($toolbar.Count -ne 1) { throw 'F_OBSERVER_UNAVAILABLE' }
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
        $window.selectedTab=$selection.runtimeId; $window.selectedTabKey=$selection.key
        $window.selectedTabIdentityKind=$selection.kind; $window.selectedTabPosition=$selection.position
    } catch {
        if(-not $AllowUnavailable) { throw }
        # Only actually observed metadata is present. No made-up tab/bounds.
        $window.observationAvailable=$false
        $window.observationError='F_OBSERVER_UNAVAILABLE'
    }
    return $window
}
function Get-Snapshot {
    $null=Get-ProcessIdentity
    $windows=@()
    $workspaceMode=Test-WorkspaceGuard
    if($workspaceMode) {
        foreach($handle in [NightlyWorkspaceWindow]::TopLevelWindows()) {
            $ownerPid=[uint32]0; $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr]$handle,[ref]$ownerPid)
            if($ownerPid -eq $script:browserPid -and [NightlyWorkspaceWindow]::ClassName([IntPtr]$handle) -eq 'MozillaWindowClass') { $windows+=@(Get-WindowSnapshot $handle -AllowUnavailable) }
        }
    } else {
        foreach($root in Get-BrowserRoots) { $windows+=@(Get-WindowSnapshot ([long]$root.Current.NativeWindowHandle) -Root $root) }
        if($windows.Count -eq 0) { throw 'F_BROWSER_NOT_FOUND' }
    }
    return @{foreground=[NightlyDesktop]::GetForegroundWindow().ToInt64().ToString();clipboardSequence=[NightlyDesktop]::GetClipboardSequenceNumber();windows=@($windows | Sort-Object hwnd);observationAvailable=(@($windows | Where-Object { -not (Test-ObservationAvailable $_) }).Count -eq 0)}
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
    $workspaceMode=Test-WorkspaceGuard
    $scoped=@{windowsStable=$true;foregroundWithinControlPolicy=$true;ownershipVerified=$true;observationAvailable=$true;reasons=@()}
    if($workspaceMode) { $scoped=Get-WorkspaceReport $after $events }
    return @{
        guardMode=$(if($workspaceMode){'workspace'}else{'strict'})
        workspaceGuardEnabled=$workspaceMode
        scopedWindowsStable=$(if($workspaceMode){$scoped.windowsStable}else{$comparison.windowsWithinControlPolicy})
        scopedBrowserForegroundWithinControlPolicy=$(if($workspaceMode){$scoped.foregroundWithinControlPolicy}else{$script:focusPolicy.AllowsForWindows([long[]]@($events | ForEach-Object Window),[long]$after.foreground,[long[]]$targetWindows)})
        workspaceOwnershipVerified=$scoped.ownershipVerified
        scopedObservationAvailable=$scoped.observationAvailable
        workspaceCreationActivationAllowed=$(if($workspaceMode){$scoped.creationActivationAllowed}else{$false})
        workspaceCreationActivationEventCount=$(if($workspaceMode){$scoped.creationActivationEventCount}else{0})
        inspectionActivationAllowed=$(if($workspaceMode){$scoped.inspectionActivationAllowed}else{$false})
        inspectionActivationEventCount=$(if($workspaceMode){$scoped.inspectionActivationEventCount}else{0})
        observationAvailable=(Test-ObservationAvailable $after)
        scopedDesktopChanges=$scoped.reasons
        workspaceGeometry=$(if($workspaceMode -and $script:workspace -and $script:workspace.hwnd){@{
            expected=@($script:workspace.snapshot.windows | Select-Object hwnd,bounds,normalBounds,restoredState,minimized)
            observed=@($after.windows | Where-Object { [long]$_.hwnd -eq $script:workspace.hwnd } | Select-Object hwnd,bounds,normalBounds,restoredState,minimized)
        }}else{$null})
        workspace=$(if($workspaceMode -and $script:workspace){@{phase=$(if($script:workspace.closing){'closing'}elseif($script:workspace.hwnd){'registered'}else{'pending'});hwnd=$(if($script:workspace.hwnd){'0x{0:X}' -f $script:workspace.hwnd}else{$null})}}else{$null})
        foregroundStable=($after.foreground -eq $baseline.foreground -and @($events | Where-Object { $_.Window.ToString() -ne $baseline.foreground }).Count -eq 0)
        clipboardStable=($after.clipboardSequence -eq $baseline.clipboardSequence)
        windowsStable=$comparison.windowsStable
        windowIdentityStable=$comparison.windowIdentityStable
        windowGeometryStable=$comparison.windowGeometryStable
        canonicalGeometryStable=$comparison.canonicalGeometryStable
        minimizedStateStable=$comparison.minimizedStateStable
        selectedTabsStable=$comparison.selectedTabsStable
        tabProviderIdentityStable=$comparison.tabProviderIdentityStable
        desktopChanges=$comparison.reasons
        initialWindowsStable=(Compare-DesktopSnapshot $baseline $after).windowsStable
        clipboardPolicy='observe-only'
        tabSelectionPolicy='observe-only'
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
        lastInvokeReturned=$script:lastInvokeReturned
        lastNativeFailure=$script:lastNativeFailure
        lastControlState=$script:lastControlState
        serviceWindowPreparation=(Get-Variable lastServiceWindowPreparation -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        consentWindowPreparation=(Get-Variable lastConsentWindowPreparation -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    }
}
function Assert-Desktop([switch]$PassThru) {
    $report=Get-GuardReport
    if(-not $report.scopedWindowsStable -or -not $report.scopedBrowserForegroundWithinControlPolicy) {
        if($report.workspaceGuardEnabled) { $reasons=@($report.scopedDesktopChanges) } else { $reasons=@($report.desktopChanges) }
        # Raw snapshot differences retain tab-selection; failures list only gates.
        $reasons=@($reasons | Where-Object { $_ -cne 'tab-selection' })
        if(-not $report.scopedBrowserForegroundWithinControlPolicy) { $reasons+='browser-focus' }
        $script:lastGuardFailure=@{reasons=$reasons;windowIdentityStable=$report.windowIdentityStable;windowGeometryStable=$report.windowGeometryStable;selectedTabsStable=$report.selectedTabsStable;clipboardStable=$report.clipboardStable;browserForegroundWithinControlPolicy=$report.browserForegroundWithinControlPolicy;workspaceGeometry=$report.workspaceGeometry}
        throw 'F_DESKTOP_CHANGED'
    }
    if($PassThru) { return $report }
}
function Prepare-Desktop {
    if($script:guardLocked) { return }
    if(Test-WorkspaceGuard) {
        # User-owned windows are observations, not a moving operation baseline.
        $null=Get-ProcessIdentity
        $script:guardLocked=$true
        return
    }
    # Settle only before any owned UI action or connection. Never retry tasks,
    # replay a native invocation, or erase an already protected interval.
    $previous=Get-Snapshot
    for($attempt=0;$attempt -lt 3;$attempt++) {
        Start-Sleep -Milliseconds 50
        $current=Get-Snapshot
        $comparison=Compare-DesktopSnapshot $previous $current
        if($comparison.windowsWithinControlPolicy) {
            if(-not (Compare-DesktopSnapshot $script:guardBaseline $current).windowsWithinControlPolicy) { $script:preflightRebases++ }
            $script:guardBaseline=$current
            $script:focusPolicy.SetCheckpoint(@([NightlyDesktop]::ForegroundEvents()).Count,[long]$current.foreground)
            $script:guardLocked=$true
            return
        }
        $previous=$current
    }
    $script:lastGuardFailure=@{reasons=@('preparation-unstable')+@($comparison.reasons | Where-Object { $_ -cne 'tab-selection' })}
    throw 'F_DESKTOP_UNSTABLE'
}
function Begin-ConsentFocus($Dialog,[int]$EventIndex) {
    if($Dialog.Current.ClassName -ne 'MozillaDialogClass' -or $Dialog.Current.AutomationId -ne 'commonDialogWindow' -or $Dialog.Current.ProcessId -ne $script:browserPid) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    if(-not $script:focusPolicy.Active) {
        $parent=[long](Get-TargetRoot).Current.NativeWindowHandle
        $script:focusPolicy.Begin($EventIndex,[long]$Dialog.Current.NativeWindowHandle,$parent)
        if(Test-WorkspaceGuard) { Start-WorkspaceFocus $EventIndex $parent ([long]$Dialog.Current.NativeWindowHandle) }
    }
}
function Finish-ConsentFocus {
    $script:nativePhase='consent-finish'
    $cleanupFailure=$null
    if($script:focusPolicy.Active) {
        if($script:consentDialogHandle -and [NightlyDesktop]::IsWindow([IntPtr]$script:consentDialogHandle)) { throw 'F_CONSENT_NOT_CLOSED' }
        try {
            $preparation=Get-Variable activeConsentWindowPreparation -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if($preparation) { Complete-ConsentWindowPreparation $preparation }
        } catch { $cleanupFailure=$_ } finally {
            $eventEnd=@([NightlyDesktop]::ForegroundEvents()).Count
            $script:focusPolicy.Complete($eventEnd,[NightlyDesktop]::GetForegroundWindow().ToInt64())
            if(Test-WorkspaceGuard) { Complete-WorkspaceFocus $eventEnd }
        }
    }
    if($cleanupFailure) { throw $cleanupFailure }
    $script:nativePhase='consent-finish-assert'
    Assert-Desktop
}
function New-ConsentWindowPreparation {
    if(-not $script:consentArmed -or -not $script:focusPolicy.Active -or $script:focusPolicy.ServiceStartActive) { throw 'F_CONSENT_SCOPE_CHANGED' }
    $root=Get-TargetRoot
    $current=$root.Current; $handle=[long]$current.NativeWindowHandle
    if($current.ProcessId -ne $script:browserPid -or $current.ClassName -ne 'MozillaWindowClass') { throw 'F_CONSENT_WINDOW_CHANGED' }
    # Sample at the final Allow boundary, not beginConsent/dialog discovery:
    # a user restore before invocation is not ours to undo. Modal owners can be disabled.
    $snapshot=Get-WindowSnapshot $handle -Root $root
    if(-not $snapshot.minimized) { return $null }
    if(-not (Compare-DesktopSnapshot @{windows=@($snapshot)} @{windows=@($snapshot)}).windowsWithinControlPolicy) { throw 'F_CONSENT_WINDOW_CHANGED' }
    $cookie='HermesNightlyConsent.'+[Guid]::NewGuid().ToString('N')
    $preparation=@{hwnd=$handle;processId=$script:browserPid;created=$script:browserCreated;cookie=$cookie;before=@{windows=@($snapshot)};invocationIssued=$false}
    $script:lastConsentWindowPreparation=@{hwnd=('0x{0:X}' -f $handle);originallyMinimized=$true;restored=$false;restorePending=$false;restoredOriginalState=$false;active=$true;cleanupError=$null}
    [NightlyWorkspaceWindow]::Claim([IntPtr]$handle,$cookie)
    $script:activeConsentWindowPreparation=$preparation
    return $preparation
}
function Assert-ConsentWindowPreparationIdentity($Preparation) {
    if(-not $script:consentArmed -or -not $script:focusPolicy.Active -or $script:focusPolicy.ServiceStartActive) { throw 'F_CONSENT_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    $handle=[IntPtr]$Preparation.hwnd
    if($Preparation.processId -ne $script:browserPid -or $Preparation.created -cne $script:browserCreated -or -not [NightlyDesktop]::IsWindow($handle)) { throw 'F_CONSENT_WINDOW_CHANGED' }
    $ownerPid=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId($handle,[ref]$ownerPid)
    if($ownerPid -ne $script:browserPid -or -not [NightlyWorkspaceWindow]::Owns($handle,$Preparation.cookie)) { throw 'F_CONSENT_WINDOW_CHANGED' }
}
function Get-ConsentWindowPreparationSnapshot($Preparation) {
    Assert-ConsentWindowPreparationIdentity $Preparation
    $snapshot=Get-WindowSnapshot $Preparation.hwnd
    if(-not (Compare-DesktopSnapshot $Preparation.before @{windows=@($snapshot)}).windowsWithinControlPolicy) { throw 'F_CONSENT_WINDOW_CHANGED' }
    Assert-ConsentWindowPreparationIdentity $Preparation
    return $snapshot
}
function Complete-ConsentWindowPreparation($Preparation) {
    try {
        if(-not $Preparation.invocationIssued) { return }
        # Allow MAY restore its parent; unlike service preparation, we have not
        # requested SW_RESTORE. Observe late changes before minimizing once.
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        do {
            $snapshot=Get-ConsentWindowPreparationSnapshot $Preparation
            if(-not $snapshot.minimized) { break }
            Start-Sleep -Milliseconds 50
        } while([DateTime]::UtcNow -lt $deadline)
        if($snapshot.minimized) {
            # A closed dialog can leave this target untouched (for example its
            # native owner is another browser window). This is observed original
            # state, not cancellation/completion of an invented restore queue.
            $script:lastConsentWindowPreparation.unchanged=$true
            $script:lastConsentWindowPreparation.restorePending=$false
            $script:lastConsentWindowPreparation.restoredOriginalState=$true
            return
        }
        $script:lastConsentWindowPreparation.restored=$true
        $script:lastConsentWindowPreparation.restorePending=$false
        try {
            $null=[NightlyWindowPlacement]::MinimizeNoActivate([IntPtr]$Preparation.hwnd,[Action]{
                # Recheck geometry as well as the lifecycle cookie after the
                # placement helper's reads. The cookie remains the LAST native read.
                $null=Get-ConsentWindowPreparationSnapshot $Preparation
            })
        } catch [System.Management.Automation.MethodInvocationException] {
            $cause=$_.Exception.GetBaseException()
            if($cause.Message -match '^F_[A-Z_]+$') { throw $cause.Message }
            throw
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        do {
            $snapshot=Get-ConsentWindowPreparationSnapshot $Preparation
            if($snapshot.minimized) { $script:lastConsentWindowPreparation.restoredOriginalState=$true; return }
            Start-Sleep -Milliseconds 50
        } while([DateTime]::UtcNow -lt $deadline)
        throw 'F_CONSENT_WINDOW_RESTORE_FAILED'
    } catch {
        $script:lastConsentWindowPreparation.cleanupError=$(if($_.Exception.Message -match '^F_[A-Z_]+$'){$_.Exception.Message}else{'F_NATIVE_UNAVAILABLE'})
        throw
    } finally {
        if([NightlyDesktop]::IsWindow([IntPtr]$Preparation.hwnd) -and [NightlyWorkspaceWindow]::Owns([IntPtr]$Preparation.hwnd,$Preparation.cookie)) { [NightlyWorkspaceWindow]::Release([IntPtr]$Preparation.hwnd,$Preparation.cookie) }
        $script:lastConsentWindowPreparation.active=$false
        $script:activeConsentWindowPreparation=$null
    }
}
function Get-TargetRoot {
    $null=Get-ProcessIdentity
    if((Test-WorkspaceGuard) -and $script:workspace -and $script:workspace.hwnd) {
        if(-not (Test-WorkspaceIdentity $script:workspace)) { throw 'F_WORKSPACE_CHANGED' }
        $root=Get-RootByHandle $script:workspace.hwnd
        if($root.Current.ProcessId -ne $script:browserPid -or $root.Current.ClassName -ne 'MozillaWindowClass' -or [long]$root.Current.NativeWindowHandle -ne $script:workspace.hwnd -or @(Find-ById $root 'TabsToolbar' -Children).Count -ne 1) { throw 'F_WORKSPACE_CHANGED' }
        return $root
    }
    $roots=@(Get-BrowserRoots)
    if((Test-WorkspaceGuard) -and $script:originalTargetHwnd) {
        try {
            # A replacement HWND is not the originally authorized UIA object.
            $current=$script:originalTargetRoot.Current
            if([NightlyDesktop]::IsWindow([IntPtr]$script:originalTargetHwnd) -and $current.ProcessId -eq $script:browserPid -and $current.NativeWindowHandle -eq $script:originalTargetHwnd -and $current.ClassName -eq 'MozillaWindowClass' -and @(Find-ById $script:originalTargetRoot 'TabsToolbar' -Children).Count -eq 1) { return $script:originalTargetRoot }
        } catch { }
        $roots=@($roots | Where-Object { [long]$_.Current.NativeWindowHandle -ne $script:originalTargetHwnd })
        if($roots.Count -ne 1) { throw 'F_WINDOW_AMBIGUOUS' }
        return $roots[0]
    }
    if($Hwnd) {
        if($Hwnd -notmatch '^0x[0-9a-fA-F]+$') { throw 'F_INVALID_HWND' }
        $numeric=[Convert]::ToInt64($Hwnd.Substring(2),16)
        $roots=@($roots | Where-Object { [long]$_.Current.NativeWindowHandle -eq $numeric })
    }
    if($roots.Count -ne 1) { throw 'F_WINDOW_AMBIGUOUS' }
    if(Test-WorkspaceGuard) { $script:originalTargetHwnd=[long]$roots[0].Current.NativeWindowHandle; $script:originalTargetRoot=$roots[0] }
    return $roots[0]
}
function Begin-Workspace([string]$Token,[bool]$AllowCreationActivation=$false,[bool]$AllowInspectionActivation=$false) {
    if(-not (Test-WorkspaceGuard) -or $script:workspace -or $Token -cnotmatch '^[A-Za-z0-9_-]{16,128}$') { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    $existing=@([NightlyWorkspaceWindow]::TopLevelWindows())
    $script:workspace=@{token=$Token;existing=$existing;processId=$script:browserPid;created=$script:browserCreated;eventStart=@([NightlyDesktop]::ForegroundEvents()).Count;eventEnd=$null;allowCreationActivation=$AllowCreationActivation;allowInspectionActivation=$AllowInspectionActivation;creationEnd=$null;hwnd=0;cookie=$null;snapshot=$null;closing=$false}
    return @{ begun=$true }
}
function Test-WorkspaceIdentity($Workspace) {
    if($Workspace.processId -ne $script:browserPid -or $Workspace.created -cne $script:browserCreated -or -not [NightlyDesktop]::IsWindow([IntPtr]$Workspace.hwnd)) { return $false }
    $ownerPid=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr]$Workspace.hwnd,[ref]$ownerPid)
    return ($ownerPid -eq $script:browserPid -and [NightlyWorkspaceWindow]::Owns([IntPtr]$Workspace.hwnd,$Workspace.cookie))
}
function Register-Workspace([string]$Token,[string]$Marker) {
    if(-not (Test-WorkspaceGuard) -or -not $script:workspace -or $script:workspace.token -cne $Token -or $script:workspace.hwnd -or [string]::IsNullOrWhiteSpace($Marker) -or $Marker.Length -lt 16 -or $Marker.Length -gt 256) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    if($script:workspace.processId -ne $script:browserPid -or $script:workspace.created -cne $script:browserCreated) { throw 'F_BROWSER_CHANGED' }
    $after=Get-Snapshot
    $found=@(foreach($root in Get-BrowserRoots) {
        $current=$root.Current; $handle=[long]$current.NativeWindowHandle
        # Do not collect/read the title of a pre-existing user window.
        if($handle -in $script:workspace.existing -or $current.ProcessId -ne $script:browserPid -or $current.ClassName -ne 'MozillaWindowClass') { continue }
        if(-not [NightlyDesktop]::IsWindow([IntPtr]$handle) -or -not [NightlyWorkspaceWindow]::IsWindowVisible([IntPtr]$handle) -or [NightlyDesktop]::IsIconic([IntPtr]$handle)) { continue }
        $ownerPid=[uint32]0; $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr]$handle,[ref]$ownerPid)
        if($ownerPid -ne $script:browserPid -or @(Find-ById $root 'TabsToolbar' -Children).Count -ne 1) { continue }
        if($current.Name.IndexOf($Marker,[StringComparison]::Ordinal) -ge 0) { $root }
    })
    if($found.Count -ne 1) { throw 'F_WORKSPACE_AMBIGUOUS' }
    $handle=[long]$found[0].Current.NativeWindowHandle
    $windows=@($after.windows | Where-Object { [long]$_.hwnd -eq $handle })
    if($windows.Count -ne 1 -or -not (Test-ObservationAvailable $windows[0]) -or $windows[0].minimized) { throw 'F_OBSERVER_UNAVAILABLE' }
    $cookie='HermesNightlyWorkspace.'+[Guid]::NewGuid().ToString('N')
    [NightlyWorkspaceWindow]::Claim([IntPtr]$handle,$cookie)
    $script:workspace.hwnd=$handle; $script:workspace.cookie=$cookie
    $script:workspace.snapshot=@{windows=@($windows[0])} | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    # Permission applies only to this verified new HWND before registration.
    # Inspection, when explicitly authorized, starts at this interval's end.
    $script:workspace.creationEnd=@([NightlyDesktop]::ForegroundEvents()).Count
    $script:workspaceHistory+=@($script:workspace)
    # Return the ownership receipt before readiness is checked. The caller must
    # assert before exposing the task API, but needs this HWND to recover safely
    # if a recorded creation-time foreground violation makes readiness fail.
    return @{hwnd=('0x{0:X}' -f $handle)}
}
function Assert-WorkspaceRequest([string]$Token,[string]$Handle) {
    if(-not (Test-WorkspaceGuard) -or -not $script:workspace -or -not $script:workspace.hwnd -or $Token -cne $script:workspace.token) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $numeric=0L
    try {
        if($Handle -cmatch '^0x[0-9a-fA-F]+$') { $numeric=[Convert]::ToInt64($Handle.Substring(2),16) }
        elseif($Handle -cmatch '^[1-9][0-9]*$') { $numeric=[long]$Handle }
        else { throw 'F_INVALID_HWND' }
    } catch { throw 'F_INVALID_HWND' }
    if($numeric -ne $script:workspace.hwnd) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
}
function Begin-WorkspaceClose([string]$Token,[string]$Handle) {
    Assert-WorkspaceRequest $Token $Handle
    if($script:workspace.closing) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    if(-not (Test-WorkspaceIdentity $script:workspace)) { throw 'F_WORKSPACE_CHANGED' }
    $script:workspace.closing=$true
    return @{closing=$true}
}
function Finish-WorkspaceClose([string]$Token,[string]$Handle) {
    Assert-WorkspaceRequest $Token $Handle
    if(-not $script:workspace.closing) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    if([NightlyDesktop]::IsWindow([IntPtr]$script:workspace.hwnd)) { throw 'F_WORKSPACE_NOT_CLOSED' }
    # Release only the confirmed vanished object; retain all failure history.
    $script:workspace.eventEnd=@([NightlyDesktop]::ForegroundEvents()).Count
    $script:workspace=$null
    return @{closed=$true}
}
function Start-WorkspaceFocus([int]$EventIndex,[long]$Parent,[long]$Dialog=0) {
    $script:workspaceFocusIntervals+=@(@{start=$EventIndex;end=$null;parent=$Parent;dialog=$Dialog})
}
function Complete-WorkspaceFocus([int]$EventIndex) {
    if($script:workspaceFocusIntervals.Count -eq 0 -or $null -ne $script:workspaceFocusIntervals[-1].end) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
    $script:workspaceFocusIntervals[-1].end=$EventIndex
}
function Get-WorkspaceReport($After,[object[]]$Events) {
    $result=@{windowsStable=$true;foregroundWithinControlPolicy=$true;ownershipVerified=$true;observationAvailable=$true;reasons=@();creationActivationAllowed=$false;creationActivationEventCount=0;inspectionActivationAllowed=$false;inspectionActivationEventCount=0}
    $owned=@($script:workspaceHistory | Where-Object { $_.hwnd })
    $result.creationActivationAllowed=(@($owned | Where-Object { $_.allowCreationActivation }).Count -gt 0)
    $result.inspectionActivationAllowed=(@($owned | Where-Object { $_.allowInspectionActivation }).Count -gt 0)
    # Authorization is for a verified owned-window interval, not proof that an
    # OS foreground event was initiated by a user rather than page/script code.
    # Completed leases retain their historical interval; a live lease must
    # still prove ownership (or be observed gone in its explicit close phase).
    $inspectionOwned=@($owned | Where-Object {
        $_.allowInspectionActivation -and ($null -ne $_.eventEnd -or (Test-WorkspaceIdentity $_) -or
            ($_.closing -and -not [NightlyDesktop]::IsWindow([IntPtr]$_.hwnd) -and @($After.windows | Where-Object hwnd -eq $_.hwnd.ToString()).Count -eq 0))
    })
    $unauthorizedActivation=$false
    $targets=[long[]]@($owned | ForEach-Object hwnd)
    $targets+=[long[]]@($script:workspaceFocusIntervals | Where-Object { $_.dialog } | ForEach-Object dialog)
    # Preserve original indexes for exceptions; project irrelevant user events
    # out of the scoped check, never out of the original foreground log.
    $scopedEvents=[long[]]@(for($index=0;$index -lt $Events.Count;$index++) {
        $event=$Events[$index]
        $relevant=@($owned | Where-Object { $_.hwnd -eq $event.Window -and $index -ge $_.eventStart -and ($null -eq $_.eventEnd -or $index -lt $_.eventEnd) }).Count -gt 0
        $creationAllowed=@($owned | Where-Object { $_.hwnd -eq $event.Window -and $_.allowCreationActivation -and $null -ne $_.creationEnd -and $index -ge $_.eventStart -and $index -lt $_.creationEnd }).Count -gt 0
        if($creationAllowed) {
            # Scope projection only. The original events/global policy remain
            # untouched and the exact allowed event count is reported separately.
            $result.creationActivationEventCount++
            0L
            continue
        }
        $inspectionAllowed=@($inspectionOwned | Where-Object { $_.hwnd -eq $event.Window -and $_.processId -eq $event.Process -and $null -ne $_.creationEnd -and $index -ge $_.creationEnd -and ($null -eq $_.eventEnd -or $index -lt $_.eventEnd) }).Count -gt 0
        if($inspectionAllowed) {
            $result.inspectionActivationEventCount++
            0L
            continue
        }
        if($relevant -and @($script:workspaceFocusIntervals | Where-Object { $index -ge $_.start -and ($null -eq $_.end -or $index -lt $_.end) -and ($event.Window -eq $_.parent -or $event.Window -eq $_.dialog) }).Count -eq 0) { $unauthorizedActivation=$true }
        $matchedDialog=@($script:workspaceFocusIntervals | Where-Object { $_.dialog -and $_.dialog -eq $event.Window -and $index -ge $_.start -and ($null -eq $_.end -or $index -lt $_.end) }).Count -gt 0
        if($relevant -or $matchedDialog) { [long]$event.Window } else { 0L }
    })
    $foreground=0L
    $activeDialog=@($script:workspaceFocusIntervals | Where-Object { $_.dialog -and $_.dialog -eq [long]$After.foreground -and $null -eq $_.end }).Count -gt 0
    if(($script:workspace -and $script:workspace.hwnd -eq [long]$After.foreground) -or $activeDialog) { $foreground=[long]$After.foreground }
    if($script:workspace -and @($inspectionOwned | Where-Object { $null -eq $_.eventEnd -and $_.hwnd -eq [long]$After.foreground }).Count -gt 0) { $foreground=0L }
    # Returning to the task parent in an old exception must not permanently
    # authorize later activations after the user has switched away and back.
    $result.foregroundWithinControlPolicy=(-not $unauthorizedActivation -and $script:focusPolicy.AllowsForWindows($scopedEvents,$foreground,$targets))
    if($script:workspace -and $script:workspace.hwnd) {
        $current=@($After.windows | Where-Object { [long]$_.hwnd -eq $script:workspace.hwnd })
        $gone=(-not [NightlyDesktop]::IsWindow([IntPtr]$script:workspace.hwnd))
        if($script:workspace.closing -and $gone -and $current.Count -eq 0) { return $result }
        $result.ownershipVerified=Test-WorkspaceIdentity $script:workspace
        $result.observationAvailable=($current.Count -eq 1 -and (Test-ObservationAvailable $current[0]))
        $comparison=Compare-DesktopSnapshot $script:workspace.snapshot @{windows=$current}
        $result.windowsStable=($result.ownershipVerified -and $result.observationAvailable -and $comparison.windowsWithinControlPolicy)
        $result.reasons=@($comparison.reasons)
        if(-not $result.ownershipVerified) { $result.reasons+=@('workspace-identity') }
        if(-not $result.observationAvailable) { $result.reasons+=@('workspace-observation-unavailable') }
    }
    return $result
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
function Assert-ServiceOwnership($ExpectedService) {
    try {
        $status=Get-Status
        if($null -eq $ExpectedService -or $ExpectedService.browser.processId -ne $status.browser.processId -or $ExpectedService.browser.created -cne $status.browser.created -or $ExpectedService.browser.executablePath -ine $status.browser.executablePath -or $ExpectedService.port -ne $status.port -or -not $status.endpoint.listening -or -not $status.endpoint.verified) { throw 'F_OWNERSHIP_CHANGED' }
        $expected=@($ExpectedService.endpointCreated)
        $actual=@($status.endpoint.created)
        if($expected.Count -eq 0 -or $actual.Count -eq 0 -or @($expected | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual -CaseSensitive).Count -gt 0) { throw 'F_OWNERSHIP_CHANGED' }
    } catch { throw 'F_OWNERSHIP_CHANGED' }
}
function Invoke-Native($Element,[switch]$WaitForEnabled,[string[]]$ExpectedNames,$ExpectedService=$null) {
    $script:lastInvocationIssued=$false
    $script:lastInvokeReturned=$false
    $script:nativePhase='pre-invoke-assert'
    Assert-Desktop
    $script:nativePhase='invoke-readiness'
    $preparation=Get-Variable activeServiceStartPreparation -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($preparation) { $null=Get-ServiceStartPreparationSnapshot $preparation }
    $current=$Element.Current
    $script:lastControlState=@{action=$script:lastNativeAction;enabled=$current.IsEnabled;offscreen=$current.IsOffscreen;invokeAvailable=$null}
    if($ExpectedNames -and $current.Name -cnotin $ExpectedNames) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
    if($current.IsOffscreen) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    if(-not $current.IsEnabled) {
        if($WaitForEnabled) { return $false }
        throw 'F_BACKGROUND_CONTROL_UNAVAILABLE'
    }
    $pattern=$null
    $script:lastControlState.invokeAvailable=$Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)
    if(-not $script:lastControlState.invokeAvailable) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    # Recheck at the UI invocation boundary, not just at Node's readback or
    # native dispatch: a stopped/restarted listener is a different service.
    if($null -ne $ExpectedService) { Assert-ServiceOwnership $ExpectedService; Assert-Desktop }
    if($preparation) { Assert-ServiceStartPreparationIdentity $preparation }
    $consentPreparation=$null
    if($WaitForEnabled -and $script:lastNativeAction -ceq 'allow-own-consent') {
        $consentPreparation=New-ConsentWindowPreparation
        if($consentPreparation) {
            $snapshot=Get-ConsentWindowPreparationSnapshot $consentPreparation
            if(-not $snapshot.minimized) {
                # A restore while taking the lease is still the user's choice.
                Complete-ConsentWindowPreparation $consentPreparation
                $consentPreparation=$null
            } else {
                Assert-ConsentWindowPreparationIdentity $consentPreparation
                $consentPreparation.invocationIssued=$true
                $script:lastConsentWindowPreparation.restorePending=$true
            }
        }
    }
    $script:lastInvocationIssued=$true
    if($WaitForEnabled -and $script:lastNativeAction -ceq 'allow-own-consent') { $script:consentInvocationAttempted=$true }
    $script:nativePhase='invoke'
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
    $script:lastInvokeReturned=$true
    # Record the completed method BEFORE an independent provider/guard read can
    # fail. An issued-but-throwing Invoke remains unknown, never successful.
    if($WaitForEnabled -and $script:lastNativeAction -ceq 'allow-own-consent') { $script:consentInvoked=$true }
    Start-Sleep -Milliseconds 120
    $script:nativePhase='post-invoke-assert'
    Assert-Desktop
    if($WaitForEnabled) { return $true }
}
function New-ServiceStartPreparation($Root) {
    $handle=[long]$Root.Current.NativeWindowHandle
    if(-not [NightlyDesktop]::IsIconic([IntPtr]$handle)) { return $null }
    $null=Get-ProcessIdentity
    $current=$Root.Current
    if($current.ProcessId -ne $script:browserPid -or $current.ClassName -ne 'MozillaWindowClass' -or -not $current.IsEnabled) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    $snapshot=Get-WindowSnapshot $handle -Root $Root
    if(-not $snapshot.minimized -or -not (Compare-DesktopSnapshot @{windows=@($snapshot)} @{windows=@($snapshot)}).windowsWithinControlPolicy) { throw 'F_SERVICE_WINDOW_CHANGED' }
    $ownerPid=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId([IntPtr]$handle,[ref]$ownerPid)
    if($ownerPid -ne $script:browserPid) { throw 'F_SERVICE_WINDOW_CHANGED' }
    $cookie='HermesNightlyServiceStart.'+[Guid]::NewGuid().ToString('N')
    [NightlyWorkspaceWindow]::Claim([IntPtr]$handle,$cookie)
    $script:lastServiceWindowPreparation=@{hwnd=('0x{0:X}' -f $handle);originallyMinimized=$true;restoreRequested=$false;restorePending=$false;restored=$false;restoredOriginalState=$false;active=$true;cleanupError=$null}
    return @{hwnd=$handle;processId=$script:browserPid;created=$script:browserCreated;cookie=$cookie;before=@{windows=@($snapshot)};restoreRequested=$false;restoreObserved=$false}
}
function Assert-ServiceStartPreparationIdentity($Preparation) {
    if(-not $script:focusPolicy.ServiceStartActive) { throw 'F_SERVICE_SCOPE_CHANGED' }
    $null=Get-ProcessIdentity
    $handle=[IntPtr]$Preparation.hwnd
    if($Preparation.processId -ne $script:browserPid -or $Preparation.created -cne $script:browserCreated -or -not [NightlyDesktop]::IsWindow($handle)) { throw 'F_SERVICE_WINDOW_CHANGED' }
    $ownerPid=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId($handle,[ref]$ownerPid)
    if($ownerPid -ne $script:browserPid -or -not [NightlyWorkspaceWindow]::Owns($handle,$Preparation.cookie)) { throw 'F_SERVICE_WINDOW_CHANGED' }
    # Owns is the final native identity read. Call this again immediately before
    # each action, after provider/placement reads that can invalidate the lease.
}
function Get-ServiceStartPreparationSnapshot($Preparation) {
    Assert-ServiceStartPreparationIdentity $Preparation
    $snapshot=Get-WindowSnapshot $Preparation.hwnd
    if(-not (Compare-DesktopSnapshot $Preparation.before @{windows=@($snapshot)}).windowsWithinControlPolicy) { throw 'F_SERVICE_WINDOW_CHANGED' }
    Assert-ServiceStartPreparationIdentity $Preparation
    return $snapshot
}
function Restore-ServiceStartWindow($Preparation) {
    if(-not $script:focusPolicy.ServiceStartActive) { throw 'F_SERVICE_SCOPE_CHANGED' }
    $snapshot=Get-ServiceStartPreparationSnapshot $Preparation
    # A user may already have restored it. Do not later minimize a window this
    # operation never restored. SW_RESTORE must not unmaximize a normal window.
    if(-not $snapshot.minimized) { return }
    $script:lastNativeAction='restore-service-start-window'
    try {
        $queued=[NightlyWindowPlacement]::Restore([IntPtr]$Preparation.hwnd,[Action]{ Assert-ServiceStartPreparationIdentity $Preparation })
    } catch [System.Management.Automation.MethodInvocationException] {
        $cause=$_.Exception.GetBaseException()
        if($cause.Message -match '^F_[A-Z_]+$') { throw $cause.Message }
        throw
    }
    $Preparation.restoreRequested=$queued
    $script:lastServiceWindowPreparation.restoreRequested=$queued
    $script:lastServiceWindowPreparation.restorePending=$queued
    if(-not $queued) { return }
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    do {
        $snapshot=Get-ServiceStartPreparationSnapshot $Preparation
        Assert-Desktop
        if(-not $snapshot.minimized) {
            $Preparation.restoreObserved=$true
            $script:lastServiceWindowPreparation.restored=$true
            $script:lastServiceWindowPreparation.restorePending=$false
            return
        }
        Start-Sleep -Milliseconds 50
    } while([DateTime]::UtcNow -lt $deadline)
    throw 'F_SERVICE_WINDOW_RESTORE_FAILED'
}
function Complete-ServiceStartPreparation($Preparation) {
    try {
        if(-not $Preparation.restoreRequested) { return }
        # Never overwrite a move, minimize an HWND replacement or
        # reclaim a different browser generation while unwinding an error.
        $snapshot=Get-ServiceStartPreparationSnapshot $Preparation
        if(-not $snapshot.minimized) {
            # The queued restore may have completed only after the startup
            # deadline. Observe it before requesting a single re-minimization.
            $Preparation.restoreObserved=$true
            $script:lastServiceWindowPreparation.restored=$true
            $script:lastServiceWindowPreparation.restorePending=$false
            $script:lastNativeAction='reminimize-service-start-window'
            try {
                $null=[NightlyWindowPlacement]::MinimizeNoActivate([IntPtr]$Preparation.hwnd,[Action]{ Assert-ServiceStartPreparationIdentity $Preparation })
            } catch [System.Management.Automation.MethodInvocationException] {
                $cause=$_.Exception.GetBaseException()
                if($cause.Message -match '^F_[A-Z_]+$') { throw $cause.Message }
                throw
            }
        }
        # Still minimized does NOT confirm cleanup of a pending SW_RESTORE.
        # Windows cannot cancel that queued action: leave the outcome unknown,
        # retain restorePending, and never queue a blind compensating command.
        if(-not $Preparation.restoreObserved) { throw 'F_SERVICE_WINDOW_RESTORE_FAILED' }
        $deadline=[DateTime]::UtcNow.AddSeconds(3)
        do {
            $snapshot=Get-ServiceStartPreparationSnapshot $Preparation
            if($snapshot.minimized) { $script:lastServiceWindowPreparation.restoredOriginalState=$true; return }
            Start-Sleep -Milliseconds 50
        } while([DateTime]::UtcNow -lt $deadline)
        throw 'F_SERVICE_WINDOW_RESTORE_FAILED'
    } finally {
        if([NightlyDesktop]::IsWindow([IntPtr]$Preparation.hwnd) -and [NightlyWorkspaceWindow]::Owns([IntPtr]$Preparation.hwnd,$Preparation.cookie)) { [NightlyWorkspaceWindow]::Release([IntPtr]$Preparation.hwnd,$Preparation.cookie) }
        $script:lastServiceWindowPreparation.active=$false
    }
}
function Set-Power([bool]$Enabled,$ExpectedService=$null,[switch]$PrepareOnly) {
    if($Enabled -and $null -ne $ExpectedService) { throw 'F_OWNERSHIP_CHANGED' }
    if($PrepareOnly -and (-not $Enabled -or (Get-Endpoint).listening)) { throw 'F_OWNERSHIP_CHANGED' }
    Prepare-Desktop
    $root=Get-TargetRoot
    if($script:focusPolicy.Active) { throw 'F_CONSENT_NOT_CLOSED' }
    if(-not $Enabled -and [NightlyDesktop]::IsIconic([IntPtr]$root.Current.NativeWindowHandle)) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    # Starting may activate the browser; stopping never opens a focus exception.
    Assert-Desktop
    $button=Get-ToolbarButton $root
    $expected=if($Enabled){'Remote control'}else{'Remote control (on)'}
    if(-not $PrepareOnly -and $button.Current.Name -cne $expected) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
    if(-not $Enabled) {
        $notification=Find-NotificationPowerOff $root
        if($notification) {
            $script:lastNativeAction='turn-off-notification'
            Invoke-Native $notification -ExpectedNames @('Turn off remote control','Disconnect') -ExpectedService $ExpectedService
            Wait-RemoteControlStopped
            return @{ requested=$false }
        }
        # Keep the existing foreground panel path, never activate a background
        # browser or substitute a similarly named web/document control.
        if([NightlyDesktop]::GetForegroundWindow().ToInt64() -ne [long]$root.Current.NativeWindowHandle) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
    }
    if($Enabled) {
        $eventStart=@([NightlyDesktop]::ForegroundEvents()).Count
        $script:focusPolicy.BeginServiceStart($eventStart,[long]$root.Current.NativeWindowHandle)
        if(Get-Variable workspaceGuardEnabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { Start-WorkspaceFocus $eventStart ([long]$root.Current.NativeWindowHandle) }
    }
    $preparation=$null; $powerFailure=$null
    $script:activeServiceStartPreparation=$null
    try {
        if($Enabled -and [NightlyDesktop]::IsIconic([IntPtr]$root.Current.NativeWindowHandle)) {
            $preparation=New-ServiceStartPreparation $root
            if($preparation -and $PrepareOnly) { $script:lastServiceWindowPreparation.purpose='stopped-state-observation' }
            $script:activeServiceStartPreparation=$preparation
            if($preparation) { Restore-ServiceStartWindow $preparation }
            $root=Get-TargetRoot
            if($preparation -and [long]$root.Current.NativeWindowHandle -ne $preparation.hwnd) { throw 'F_NATIVE_SCOPE_CHANGED' }
            $button=Get-ToolbarButton $root
            if(-not $PrepareOnly -and $button.Current.Name -cne $expected) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
        }
        # Refresh stale minimized chrome only within explicit restart's START
        # preparation. This branch never opens a panel or invokes a toggle.
        if($PrepareOnly) { $null=$button.Current.Name; return @{prepared=$true} }
        if($Enabled -and ($button.Current.IsOffscreen -or [NightlyDesktop]::GetForegroundWindow().ToInt64() -ne [long]$root.Current.NativeWindowHandle)) {
            # Covered onscreen controls may accept Invoke without opening a popup.
            # Use only the existing start interval and a fresh verified control;
            # never retry an already issued invocation.
            $serviceWindow=[long]$root.Current.NativeWindowHandle
            if($preparation) { $null=Get-ServiceStartPreparationSnapshot $preparation }
            $currentRoot=$root.Current
            $null=Get-ProcessIdentity
            if($currentRoot.ProcessId -ne $script:browserPid -or $currentRoot.ClassName -ne 'MozillaWindowClass' -or $currentRoot.IsOffscreen -or -not $currentRoot.IsKeyboardFocusable -or -not $currentRoot.IsEnabled -or -not $button.Current.IsEnabled) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
            $script:lastNativeAction='focus-service-start-window'
            if($preparation) { Assert-ServiceStartPreparationIdentity $preparation }
            try { $root.SetFocus() } catch { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
            # UIA SetFocus returning is not evidence of native activation.
            # Observe a settled foreground before issuing the one panel Invoke;
            # do not refocus or replay when Windows/user retains foreground.
            $focusDeadline=[DateTime]::UtcNow.AddSeconds(2)
            $focusedSince=$null
            do {
                Assert-Desktop
                if([NightlyDesktop]::GetForegroundWindow().ToInt64() -eq $serviceWindow) {
                    if($null -eq $focusedSince) { $focusedSince=[DateTime]::UtcNow }
                    if(([DateTime]::UtcNow-$focusedSince).TotalMilliseconds -ge 250) { break }
                } else { $focusedSince=$null }
                Start-Sleep -Milliseconds 50
            } while([DateTime]::UtcNow -lt $focusDeadline)
            if($null -eq $focusedSince -or ([DateTime]::UtcNow-$focusedSince).TotalMilliseconds -lt 250) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
            Assert-Desktop
            $root=Get-TargetRoot
            if([long]$root.Current.NativeWindowHandle -ne $serviceWindow) { throw 'F_NATIVE_SCOPE_CHANGED' }
            $button=Get-ToolbarButton $root
            if($button.Current.Name -cne $expected) { throw 'F_REMOTE_CONTROL_STATE_CHANGED' }
        }
        $toggle=Find-PowerToggle
        if(-not $toggle) {
            if($Enabled -and [NightlyDesktop]::GetForegroundWindow().ToInt64() -ne [long]$root.Current.NativeWindowHandle) { throw 'F_BACKGROUND_CONTROL_UNAVAILABLE' }
            $script:lastNativeAction='open-remote-panel'
            Invoke-Native $button -ExpectedNames @($expected) -ExpectedService $ExpectedService
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
        Invoke-Native $toggle -ExpectedService $ExpectedService
        if(Find-PowerToggle) {
            $script:lastNativeAction='close-remote-panel'
            Invoke-Native (Get-ToolbarButton (Get-TargetRoot))
        }
        if(-not $Enabled) { Wait-RemoteControlStopped }
        return @{ requested=$Enabled }
    } catch { $powerFailure=$_; throw } finally {
        $cleanupFailure=$null
        try { if($preparation) { Complete-ServiceStartPreparation $preparation } } catch {
            $cleanupFailure=$_
            $script:lastServiceWindowPreparation.cleanupError=$(if($_.Exception.Message -match '^F_[A-Z_]+$'){$_.Exception.Message}else{'F_NATIVE_UNAVAILABLE'})
        }
        try {
            if($Enabled -and $script:focusPolicy.ServiceStartActive) {
                $eventEnd=@([NightlyDesktop]::ForegroundEvents()).Count
                $script:focusPolicy.Complete($eventEnd,[NightlyDesktop]::GetForegroundWindow().ToInt64())
                if(Get-Variable workspaceGuardEnabled -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { Complete-WorkspaceFocus $eventEnd }
                Assert-Desktop
            }
        } catch { if(-not $cleanupFailure) { $cleanupFailure=$_ } } finally {
            $script:activeServiceStartPreparation=$null
        }
        if($cleanupFailure -and -not $powerFailure) { throw $cleanupFailure }
    }
}
function Find-NotificationPowerOff($Root) {
    # This direct chrome toolbar anchor excludes tab panels and web documents.
    # Nightly RemoteControlBanner uses the same stopServers callback for the
    # running-state "Turn off remote control" and connected-state "Disconnect".
    if($Root.Current.ClassName -ne 'MozillaWindowClass' -or $Root.Current.ProcessId -ne $script:browserPid) { throw 'F_NATIVE_UNAVAILABLE' }
    $bars=@(Find-ById $Root 'notifications-toolbar' -Children)
    if($bars.Count -gt 1) { throw 'F_NATIVE_AMBIGUOUS' }
    if($bars.Count -eq 0) { return $null }
    $bar=$bars[0]
    if($bar.Current.ControlType -ne [System.Windows.Automation.ControlType]::ToolBar -or $bar.Current.ProcessId -ne $script:browserPid) { throw 'F_NATIVE_UNAVAILABLE' }
    $buttons=@()
    $queue=[System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($bar)
    while($queue.Count -gt 0) {
        $container=$queue.Dequeue()
        foreach($child in $container.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)) {
            if($child.Current.ProcessId -ne $script:browserPid -or $child.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document) { continue }
            if($child.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $child.Current.Name -cin @('Turn off remote control','Disconnect')) { $buttons+=@($child) }
            $queue.Enqueue($child)
        }
    }
    if($buttons.Count -gt 1) { throw 'F_NATIVE_AMBIGUOUS' }
    if($buttons.Count -eq 1) { return $buttons[0] }
    return $null
}
function Wait-RemoteControlStopped {
    # Invocation is not evidence of shutdown. Poll only observations, not actions.
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    do {
        Assert-Desktop
        $status=Get-Status
        if($status.toolbarAvailable -and -not $status.toolbarRunning -and -not $status.endpoint.listening) {
            $button=Get-ToolbarButton (Get-TargetRoot)
            if($button.Current.Name -ceq 'Remote control') { return }
        }
        Start-Sleep -Milliseconds 100
    } while([DateTime]::UtcNow -lt $deadline)
    throw 'F_REMOTE_CONTROL_STATE_CHANGED'
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
        # Do not title-scan user main windows (including minimized providers
        # with an unavailable tab strip). The legacy strict matcher is retained.
        if((Test-WorkspaceGuard) -and $_.Current.ClassName -eq 'MozillaWindowClass' -and $_.Current.AutomationId -ne 'commonDialogWindow') { return $false }
        $_.Current.ClassName -in @('MozillaWindowClass','MozillaDialogClass') -and
        $_.Current.Name -match '^Allow remote control\?(?:\s*-.*)?$' -and
        @(Find-ById $_ 'TabsToolbar' -Children).Count -eq 0
    } | Sort-Object { $_.Current.NativeWindowHandle } -Unique)
}
function Poll-Consent {
    if(-not $script:consentArmed) { throw 'F_CONSENT_NOT_ARMED' }
    if($script:consentInvocationAttempted -and -not $script:consentInvoked) { throw 'F_CONSENT_INVOCATION_UNCONFIRMED' }
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
    $closed=(-not [NightlyDesktop]::IsWindow([IntPtr]$script:consentDialogHandle))
    if($closed) { Finish-ConsentFocus }
    return @{ seen=$true; invoked=$true; closed=$closed }
}
function Cancel-Consent {
    if(-not $script:consentArmed -or -not $script:consentDialogHandle -or $script:consentInvoked -or $script:consentInvocationAttempted) { return @{ cancelled=$false } }
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
function Get-PendingConsentShape($Dialog) {
    if($Dialog.Current.ClassName -ne 'MozillaDialogClass' -or $Dialog.Current.AutomationId -ne 'commonDialogWindow' -or $Dialog.Current.ProcessId -ne $script:browserPid -or -not $Dialog.Current.NativeWindowHandle) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $elements=@($Dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition))
    $allows=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq 'Allow' })
    $denies=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq 'Deny' })
    $checks=@($elements | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox })
    $messages=@(Find-ById $Dialog 'infoBody')
    if($allows.Count -ne 1 -or $denies.Count -ne 1 -or $checks.Count -ne 1 -or $messages.Count -ne 1) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    if($checks[0].Current.AutomationId -ne 'checkbox' -or $checks[0].Current.Name -cne 'Remember my decision until the browser exits' -or $messages[0].Current.Name -cne $script:consentMessage) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    foreach($element in @($allows[0],$denies[0],$checks[0],$messages[0])) {
        if($element.Current.ProcessId -ne $script:browserPid) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    }
    $checkbox=[System.Windows.Automation.TogglePattern]$checks[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if($checkbox.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'F_CONSENT_SCOPE_CHANGED' }
}
function Deny-PendingConsent {
    # Explicit opt-in only: normal beginConsent still refuses existing dialogs.
    # Reject via native WM_CLOSE; never approve, toggle Remember, or reset sessions.
    Prepare-Desktop
    Assert-Desktop
    if($script:consentArmed -or $script:focusPolicy.Active) { throw 'F_CONSENT_SCOPE_CHANGED' }
    $dialogs=@(Get-ConsentDialogs)
    if($dialogs.Count -gt 1) { throw 'F_CONSENT_AMBIGUOUS' }
    if($dialogs.Count -eq 0) { return @{ closed=$false } }
    $dialog=$dialogs[0]
    Get-PendingConsentShape $dialog
    $handle=[IntPtr]$dialog.Current.NativeWindowHandle
    $ownerPid=[uint32]0
    $null=[NightlyDesktop]::GetWindowThreadProcessId($handle,[ref]$ownerPid)
    if($ownerPid -ne $script:browserPid -or -not [NightlyDesktop]::IsWindow($handle)) { throw 'F_CONSENT_SHAPE_UNKNOWN' }
    $script:consentDialogHandle=$handle.ToInt64()
    Begin-ConsentFocus $dialog (@([NightlyDesktop]::ForegroundEvents()).Count)
    Assert-Desktop
    Get-PendingConsentShape $dialog
    $script:lastNativeAction='deny-pending-consent'
    $script:lastInvocationIssued=$false
    [NightlyDesktop]::CloseResetConsent($handle)
    $deadline=[DateTime]::UtcNow.AddSeconds(3)
    while([NightlyDesktop]::IsWindow($handle) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if([NightlyDesktop]::IsWindow($handle)) { throw 'F_CONSENT_CLOSE_FAILED' }
    Finish-ConsentFocus
    if(@(Get-ConsentDialogs).Count -gt 0) { throw 'F_CONSENT_NOT_CLOSED' }
    $script:consentDialogHandle=0
    return @{ closed=$true }
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
            $script:nativePhase='dispatch'
            $data=switch($request.op) {
                'enableWorkspaceGuard' {
                    if(-not (Test-WorkspaceGuard) -and ($script:guardLocked -or $script:focusPolicy.Active -or $script:consentArmed)) { throw 'F_WORKSPACE_SCOPE_CHANGED' }
                    $script:workspaceGuardEnabled=$true
                    @{ enabled=$true }
                }
                'status' { Get-Status }
                'beginWorkspace' {
                    $allowCreationActivation=$false
                    if($request.PSObject.Properties['allowCreationActivation']) {
                        if($request.allowCreationActivation -isnot [bool]) { throw 'F_INVALID_ARGUMENT' }
                        $allowCreationActivation=$request.allowCreationActivation
                    }
                    $allowInspectionActivation=$false
                    if($request.PSObject.Properties['allowInspectionActivation']) {
                        if($request.allowInspectionActivation -isnot [bool]) { throw 'F_INVALID_ARGUMENT' }
                        $allowInspectionActivation=$request.allowInspectionActivation
                    }
                    Begin-Workspace $request.token $allowCreationActivation $allowInspectionActivation
                }
                'registerWorkspace' { Register-Workspace $request.token $request.marker }
                'beginWorkspaceClose' { Begin-WorkspaceClose $request.token $request.hwnd }
                'finishWorkspaceClose' { Finish-WorkspaceClose $request.token $request.hwnd }
                'marionetteEndpoint' { Get-Endpoint 2828 }
                'closeResetConsent' { Close-ResetConsent }
                'denyPendingConsent' { Deny-PendingConsent }
                'power' {
                    $prepareOnly=$false
                    if($request.PSObject.Properties['prepareOnly']) {
                        if($request.prepareOnly -isnot [bool]) { throw 'F_INVALID_NATIVE_OPERATION' }
                        $prepareOnly=$request.prepareOnly
                    }
                    if($prepareOnly) {
                        if(-not $request.PSObject.Properties['restartAuthorized'] -or $request.restartAuthorized -isnot [bool] -or -not $request.restartAuthorized -or $request.enabled -isnot [bool] -or -not $request.enabled) { throw 'F_RESET_AUTHORIZATION_REQUIRED' }
                        Set-Power $true -PrepareOnly
                    } elseif(-not [bool]$request.enabled -and $request.PSObject.Properties['expectedService']) {
                        Assert-ServiceOwnership $request.expectedService
                        Set-Power $false -ExpectedService $request.expectedService
                    } else { Set-Power ([bool]$request.enabled) }
                }
                'beginConsent' {
                    Prepare-Desktop
                    Assert-Desktop
                    if(@(Get-ConsentDialogs).Count -gt 0) { throw 'F_CONSENT_ALREADY_PRESENT' }
                    $script:consentArmed=$true; $script:consentInvoked=$false; $script:consentInvocationAttempted=$false; $script:consentSeen=$false; $script:consentDialogHandle=0
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
            $script:lastNativeFailure=Get-NativeFailure $_
            @{ id=$(if($request){$request.id}else{0}); ok=$false; error=$code; diagnostic=$script:lastNativeFailure } | ConvertTo-Json -Compress -Depth 8
        }
        [Console]::Out.Flush()
    }
} catch {
    $code=if($_.Exception.Message -match '^F_[A-Z_]+$'){$_.Exception.Message}else{'F_NATIVE_UNAVAILABLE'}
    @{ ready=$false; error=$code; diagnostic=(Get-NativeFailure $_) } | ConvertTo-Json -Compress -Depth 8
    exit 1
} finally {
    [NightlyDesktop]::Stop()
}
