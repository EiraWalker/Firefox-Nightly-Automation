$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Replay Poll-Consent with native-control state only; no browser or desktop access.
Add-Type @'
namespace ConsentReplay {
 public static class ControlType { public static string Button="button", CheckBox="checkbox"; }
 public enum TreeScope { Descendants }
 public static class Condition { public static object TrueCondition=new object(); }
 public enum ToggleState { Off, On }
 public class TogglePattern {
  public static object Pattern=new object();
  public class State { public ToggleState ToggleState=ToggleState.Off; }
  public State Current=new State();
 }
 public class InvokePattern {
  public static object Pattern=new object();
  public static int Invocations=0;
  public void Invoke() { Invocations++; }
 }
}
public static class NightlyDesktop { public static bool IsWindow(System.IntPtr h) { return false; } }
'@
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../src/native.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native parse failed'}
foreach($name in @('Poll-Consent','Invoke-Native')) {
 $definition=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression ($definition.Extent.Text.Replace('[System.Windows.Automation.','[ConsentReplay.'))
}
function Control($Name,$Type) { [pscustomobject]@{Current=[pscustomobject]@{Name=$Name;ControlType=$Type;IsEnabled=$true;IsOffscreen=$false}} }
$allow=Control 'Allow' 'button';$deny=Control 'Deny' 'button'
$allow | Add-Member ScriptMethod TryGetCurrentPattern {param($kind,$pattern) $pattern.Value=[ConsentReplay.InvokePattern]::new();return $script:invokeAvailable}
$checkbox=Control 'Remember my decision until the browser exits' 'checkbox'
$checkbox | Add-Member ScriptMethod GetCurrentPattern {param($pattern) return $script:toggle}
$dialog=[pscustomobject]@{Current=[pscustomobject]@{ClassName='MozillaDialogClass';AutomationId='commonDialogWindow';NativeWindowHandle=42}}
$dialog | Add-Member ScriptMethod FindAll {param($scope,$condition) return @($script:allow,$script:deny,$script:checkbox)}
function Get-ConsentDialogs {return @($script:dialog)}
function Find-ById {param($root,$id) return [pscustomobject]@{Current=[pscustomobject]@{Name=$script:consentMessage}}}
function Assert-Desktop {
 $script:assertions++
 if($script:disableOnAssertion -eq $script:assertions){$script:allow.Current.IsEnabled=$false}
}
function Begin-ConsentFocus {}
function Finish-ConsentFocus {}
function Reset {
 $script:consentArmed=$true;$script:consentInvoked=$false;$script:consentSeen=$false;$script:consentFocusStart=0
 $script:consentMessage='verified native message';$script:consentDialogHandle=0
 [ConsentReplay.InvokePattern]::Invocations=0;$script:assertions=0;$script:disableOnAssertion=0
 $script:toggle=[ConsentReplay.TogglePattern]::new()
 $script:invokeAvailable=$true
 $script:allow.Current.IsEnabled=$true;$script:allow.Current.IsOffscreen=$false
}
Reset
$allow.Current.IsEnabled=$false
$pending=Poll-Consent
if(-not $pending.seen -or $pending.invoked -or $pending.closed -or [ConsentReplay.InvokePattern]::Invocations -ne 0){throw 'Disabled Allow must wait without invoking'}
if($script:lastControlState.enabled -or $script:lastControlState.offscreen -or $null -ne $script:lastControlState.invokeAvailable -or $script:lastInvocationIssued){throw 'Pending control diagnostics must describe the observed state'}
$allow.Current.IsEnabled=$true
$ready=Poll-Consent
if(-not $ready.invoked -or -not $ready.closed -or [ConsentReplay.InvokePattern]::Invocations -ne 1){throw 'Ready Allow must be invoked once'}
$null=Poll-Consent
if([ConsentReplay.InvokePattern]::Invocations -ne 1){throw 'Approval must not be replayed'}
Reset
$script:disableOnAssertion=2
$pending=Poll-Consent
if($pending.invoked -or [ConsentReplay.InvokePattern]::Invocations -ne 0){throw 'Allow disabled between discovery and invocation must wait'}
Reset
$allow.Current.IsEnabled=$false;$toggle.Current.ToggleState=[ConsentReplay.ToggleState]::On
try{Poll-Consent;throw 'Remember choice must still be rejected'}catch{if($_.Exception.Message -ne 'F_CONSENT_SCOPE_CHANGED'){throw}}
Reset
$allow.Current.IsOffscreen=$true
try{Poll-Consent;throw 'Offscreen Allow must still fail'}catch{if($_.Exception.Message -ne 'F_BACKGROUND_CONTROL_UNAVAILABLE'){throw}}
Reset
$script:invokeAvailable=$false
try{Poll-Consent;throw 'Missing InvokePattern must still fail'}catch{if($_.Exception.Message -ne 'F_BACKGROUND_CONTROL_UNAVAILABLE'){throw}}
if($script:lastControlState.invokeAvailable -or $script:lastInvocationIssued){throw 'Unavailable InvokePattern must not report an invocation'}
Reset
$allow.Current.IsEnabled=$false
try{Invoke-Native $allow;throw 'Ordinary native actions must reject disabled controls'}catch{if($_.Exception.Message -ne 'F_BACKGROUND_CONTROL_UNAVAILABLE'){throw}}
@{passed=6}|ConvertTo-Json -Compress
