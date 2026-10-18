$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$source=Join-Path $PSScriptRoot '../src'
Add-Type -Path (Join-Path $source 'consent-focus.cs')
# No desktop hooks, UIA reads, browser connection, or clipboard writes in this fixture.
Add-Type @'
using System;
public sealed class ReplayEvent { public long Window; public int Process; }
public static class NightlyDesktop {
    public static ReplayEvent[] Events = new ReplayEvent[0];
    public static ReplayEvent[] ForegroundEvents() { return Events; }
    public static uint GetWindowThreadProcessId(IntPtr window, out uint process) { process = window.ToInt64() == 100 ? 42u : 43u; return 1; }
}
'@
if(Test-Path -LiteralPath (Join-Path $source 'desktop-policy.ps1')) { . (Join-Path $source 'desktop-policy.ps1') }
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'native.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Native source failed to parse' }
foreach($name in @('Get-GuardReport','Assert-Desktop','Prepare-Desktop')) {
    $definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if($definition) { Invoke-Expression $definition.Extent.Text }
}
function Snapshot([string]$Runtime='provider-1',[string]$Key='id:tab-a',[int]$Clipboard=1,[int]$Left=0,[bool]$Minimized=$false) {
    return @{foreground='10';clipboardSequence=$Clipboard;windows=@(@{hwnd='100';minimized=$Minimized;bounds=@($Left,0,100,100);selectedTab=$Runtime;selectedTabKey=$Key;selectedTabIdentityKind='automation-id'})}
}
function Reset-Replay {
    $script:baseline=Snapshot
    $script:guardBaseline=$script:baseline
    $script:snapshot=Snapshot
    $script:guardLocked=$false
    $script:preflightRebases=0
    $script:lastGuardFailure=$null
    $script:browserPid=42
    $script:lastNativeAction=$null
    $script:lastInvocationIssued=$false
    $script:lastControlState=$null
    $script:focusPolicy=[ConsentFocusPolicy]::new(10)
    $script:samples=$null
    $script:sampleIndex=0
    [NightlyDesktop]::Events=@()
}
function Get-Snapshot {
    if($script:samples) {
        $index=[Math]::Min($script:sampleIndex,$script:samples.Count-1)
        $script:sampleIndex++
        return $script:samples[$index]
    }
    return $script:snapshot
}
function Verdict {
    try { Assert-Desktop; return 'pass' } catch { return $_.Exception.Message }
}
$checks=@()
Reset-Replay
$script:snapshot=Snapshot 'provider-recreated'
$checks+=@{name='provider runtime ID churn is not a tab switch';actual=(Verdict);expected='pass'}
$report=Get-GuardReport
$checks+=@{name='provider churn remains observable';actual=($report.ContainsKey('tabProviderIdentityStable') -and -not $report.tabProviderIdentityStable);expected=$true}
Reset-Replay
$script:snapshot=Snapshot -Clipboard 2
$checks+=@{name='user copying in another app does not abort the operation';actual=(Verdict);expected='pass'}
$checks+=@{name='clipboard observation is not falsified';actual=(Get-GuardReport).clipboardStable;expected=$false}
Reset-Replay
$script:snapshot=Snapshot -Key 'id:tab-b'
$checks+=@{name='real tab selection changes after the checkpoint are rejected';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:snapshot=Snapshot -Left 5
$checks+=@{name='window movement after the checkpoint is rejected';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:snapshot=Snapshot -Minimized $true
$checks+=@{name='window minimization after the checkpoint is rejected';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:snapshot=Snapshot
$script:snapshot.windows[0].hwnd='101'
$checks+=@{name='browser window replacement is rejected';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:samples=@((Snapshot -Key 'id:user-selected'),(Snapshot -Key 'id:user-selected'))
try { Prepare-Desktop; $actual=Verdict } catch { $actual=$_.Exception.Message }
$checks+=@{name='idle preparation accepts a stable user-selected tab before connection';actual=$actual;expected='pass'}
Reset-Replay
$script:guardLocked=$true
$script:snapshot=Snapshot -Key 'id:tab-b'
try { Prepare-Desktop; $actual=Verdict } catch { $actual=$_.Exception.Message }
$checks+=@{name='preparation never rebases after the operation is locked';actual=$actual;expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:samples=@((Snapshot -Key 'id:a'),(Snapshot -Key 'id:b'),(Snapshot -Key 'id:c'),(Snapshot -Key 'id:d'))
try { Prepare-Desktop; $actual='pass' } catch { $actual=$_.Exception.Message }
$checks+=@{name='continuously changing browser state exhausts a bounded preparation';actual=$actual;expected='F_DESKTOP_UNSTABLE'}
$checks+=@{name='preparation samples are bounded';actual=($script:sampleIndex -le 4);expected=$true}
Reset-Replay
$script:snapshot=Snapshot -Key 'id:tab-b'
$null=Verdict
$report=Get-GuardReport
$checks+=@{name='failure preserves the exact tab-selection reason';actual=($report.ContainsKey('lastFailure') -and $report.lastFailure -and 'tab-selection' -in $report.lastFailure.reasons);expected=$true}
Reset-Replay
$script:samples=@((Snapshot),(Snapshot))
[NightlyDesktop]::Events=@([ReplayEvent]@{Window=100;Process=42})
$script:samples[0].foreground='100'; $script:samples[1].foreground='100'
try { Prepare-Desktop; $actual=Verdict } catch { $actual=$_.Exception.Message }
$checks+=@{name='user focus before the checkpoint is not attributed to the tool';actual=$actual;expected='pass'}
[NightlyDesktop]::Events+=@([ReplayEvent]@{Window=101;Process=42})
$script:samples[0].windows+=@(@{hwnd='101';minimized=$false;bounds=@(0,0,100,100);selectedTab='r2';selectedTabKey='id:x';selectedTabIdentityKind='automation-id'})
$checks+=@{name='new browser activation after the checkpoint cannot be hidden';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
$script:samples=@((Snapshot),(Snapshot))
Prepare-Desktop
[NightlyDesktop]::Events=@([ReplayEvent]@{Window=100;Process=42})
$checks+=@{name='target focus outside an approved interval is still rejected';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
$checks+=@{name='target focus failure has a precise reason';actual=('browser-focus' -in (Get-GuardReport).lastFailure.reasons);expected=$true}
Reset-Replay
$policy=[ConsentFocusPolicy]::new(10)
$policy.Begin(0,200,100)
try {$policy.SetCheckpoint(1,10);$actual='pass'} catch {$actual=$_.Exception.InnerException.Message}
$checks+=@{name='a checkpoint cannot erase an already owned interval';actual=$actual;expected='F_CONTROL_CHECKPOINT_INVALID'}
$tabs=@(@{automationId='first';runtimeId='r1';selected=$false},@{automationId='second';runtimeId='r2';selected=$true})
$selection=Get-TabSelection $tabs
$checks+=@{name='selection uses a unique automation ID within its tab strip';actual=$selection.key;expected='id:second'}
$tabs[0].automationId='same';$tabs[1].automationId='same'
$checks+=@{name='duplicate automation IDs fall back to the selected position';actual=(Get-TabSelection $tabs).key;expected='position:1'}
$tabs[0].automationId='';$tabs[1].automationId=''
$checks+=@{name='missing automation IDs fall back to the selected position';actual=(Get-TabSelection $tabs).key;expected='position:1'}
$tabs[1].runtimeId='new-provider'
$checks+=@{name='position identity does not depend on provider runtime IDs';actual=(Get-TabSelection $tabs).key;expected='position:1'}
try {Get-TabSelection @();$actual='pass'} catch {$actual=$_.Exception.Message}
$checks+=@{name='an empty tab strip is an observer failure';actual=$actual;expected='F_OBSERVER_UNAVAILABLE'}
$tabs[1].selected=$false
try {Get-TabSelection $tabs;$actual='pass'} catch {$actual=$_.Exception.Message}
$checks+=@{name='missing selected tab is an observer failure';actual=$actual;expected='F_OBSERVER_UNAVAILABLE'}
$tabs[0].selected=$true;$tabs[1].selected=$true
try {Get-TabSelection $tabs;$actual='pass'} catch {$actual=$_.Exception.Message}
$checks+=@{name='ambiguous selected tabs are an observer failure';actual=$actual;expected='F_OBSERVER_UNAVAILABLE'}
Reset-Replay
$script:snapshot=Snapshot
$other=@{hwnd='200';minimized=$false;bounds=@(0,0,100,100);selectedTab='r2';selectedTabKey='id:other';selectedTabIdentityKind='automation-id'}
$script:guardBaseline.windows+=@($other)
$script:snapshot.windows=@($other,$script:snapshot.windows[0])
$checks+=@{name='window enumeration order does not cause a false desktop change';actual=(Verdict);expected='pass'}
Reset-Replay
$script:baseline.windows[0].selectedTabPosition=1
$script:snapshot.windows[0].selectedTabPosition=1
$script:snapshot.windows[0].selectedTabIdentityKind='tab-position'
$script:snapshot.windows[0].selectedTabKey='position:1'
$checks+=@{name='temporary AutomationId loss does not manufacture a tab switch';actual=(Verdict);expected='pass'}
$script:snapshot.windows[0].selectedTabPosition=0
$checks+=@{name='position fallback still detects a genuine selection change';actual=(Verdict);expected='F_DESKTOP_CHANGED'}
Reset-Replay
function Get-ConsentDialogs { return @() }
$script:samples=@((Snapshot -Key 'id:user-current'),(Snapshot -Key 'id:user-current'))
$switch=$ast.Find({param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$request.op'},$true)
$arm=$switch.Clauses | Where-Object { $_.Item1.SafeGetValue() -eq 'beginConsent' }
$body=$arm.Item2.Extent.Text
try { $null=& ([scriptblock]::Create($body.Substring(1,$body.Length-2)));$actual='pass' } catch {$actual=$_.Exception.Message}
$checks+=@{name='actual beginConsent dispatch settles state before arming the connection';actual=$actual;expected='pass'}
$checks+=@{name='actual beginConsent dispatch locks and arms exactly once';actual=($script:guardLocked -and $script:consentArmed -and $script:preflightRebases -eq 1);expected=$true}
Reset-Replay
$script:guardLocked=$true
$script:samples=@((Snapshot))
$assertClause=$switch.Clauses | Where-Object { $_.Item1.SafeGetValue() -eq 'assert' }
$body=$assertClause.Item2.Extent.Text
$null=& ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
$checks+=@{name='an assertion returns the exact snapshot it validated';actual=$script:sampleIndex;expected=1}
ConvertTo-Json -InputObject $checks -Depth 6 -Compress
