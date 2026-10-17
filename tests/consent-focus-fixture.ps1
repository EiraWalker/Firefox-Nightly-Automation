$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot '../src/consent-focus.cs')
$checks=@()
function Check([string]$Name,$Policy,[long[]]$Events,[long]$Foreground,[bool]$Expected) {
    $script:checks+=@{name=$Name;actual=$Policy.Allows($Events,$Foreground);expected=$Expected}
}
$policy=[ConsentFocusPolicy]::new(101)
Check 'unchanged desktop passes without consent' $policy @() 101 $true
Check 'main window activation outside consent is rejected' $policy @(201) 201 $false
$policy.Begin(0,301,201)
Check 'matched consent may enter foreground' $policy @(301) 301 $true
Check 'consent may return focus to its browser' $policy @(301,201) 201 $true
Check 'another dialog is rejected during consent' $policy @(302) 302 $false
Check 'another application is rejected during consent' $policy @(301,202) 202 $false
$policy.Complete(2,201)
Check 'completed approval permits its recorded transition' $policy @(301,201) 201 $true
Check 'focus changes after approval are rejected' $policy @(301,201,202) 202 $false
Check 'closing the interval cannot hide an unrelated earlier event' $policy @(301,202) 201 $false
$policy.Begin(3,303,201)
Check 'a second consent retains checks between the two approvals' $policy @(301,201,201,303) 303 $true
Check 'a second consent cannot hide an unrelated event between approvals' $policy @(301,201,202,303) 303 $false
$policy=[ConsentFocusPolicy]::new(101)
$policy.Begin(1,301,201)
Check 'focus changes before approval are rejected' $policy @(202,301) 301 $false
$policy=[ConsentFocusPolicy]::new(101)
$policy.Begin(0,301,201)
$policy.Complete(1,202)
Check 'an unrelated final foreground is not adopted as the new baseline' $policy @(301) 202 $false
$policy=[ConsentFocusPolicy]::new(101)
$policy.BeginServiceStart(0,201)
Check 'service start may activate the verified browser' $policy @(201) 201 $true
Check 'service start rejects a different browser window' $policy @(202) 202 $false
Check 'service start rejects an unrelated dialog' $policy @(301) 301 $false
$script:checks+=@{name='service activation is not reported as consent-only';actual=$policy.AllowsConsentOnly(@(201),201);expected=$false}
$policy.Complete(1,201)
Check 'service start completion retains its activation' $policy @(201) 201 $true
Check 'service completion does not permit later focus changes' $policy @(201,202) 202 $false
$policy.Begin(1,301,201)
Check 'consent can follow service start' $policy @(201,301,201) 201 $true
Check 'consent cannot hide unrelated service-start events' $policy @(202,301) 301 $false
$policy.Complete(3,201)
Check 'completed service and consent remain valid' $policy @(201,301,201) 201 $true
$policy=[ConsentFocusPolicy]::new(101)
$policy.BeginServiceStart(1,201)
Check 'service start cannot hide an earlier unrelated event' $policy @(202,201) 201 $false
$policy=[ConsentFocusPolicy]::new(101)
$policy.BeginServiceStart(0,201)
$policy.Complete(1,202)
Check 'service start cannot adopt an unrelated final foreground' $policy @(201) 202 $false
$policy=[ConsentFocusPolicy]::new(101)
$script:checks+=@{name='other-app activity does not block a background connection';actual=$policy.AllowsForWindows(@(202,203),203,@(201,301));expected=$true}
$script:checks+=@{name='target window activation before consent is still rejected';actual=$policy.AllowsForWindows(@(202,201),201,@(201,301));expected=$false}
$policy.Begin(1,301,201)
$script:checks+=@{name='other apps retain event indexes around matched native consent';actual=$policy.AllowsForWindows(@(202,301,202,201),201,@(201,301));expected=$true}
$script:checks+=@{name='a different target dialog is still rejected';actual=$policy.AllowsForWindows(@(202,302),302,@(201,301,302));expected=$false}
$policy.Complete(4,201)
$script:checks+=@{name='other-app activity after approved consent does not block';actual=$policy.AllowsForWindows(@(202,301,202,201,203),203,@(201,301));expected=$true}
$script:checks+=@{name='raw focus policy still exposes other-app changes';actual=$policy.Allows(@(202,301,202,201,203),203);expected=$false}
$script:checks+=@{name='different target window after approval is still rejected';actual=$policy.AllowsForWindows(@(202,301,202,201,204),204,@(201,301,204));expected=$false}
$policy=[ConsentFocusPolicy]::new(101)
$policy.Begin(0,301,201)
$policy.Complete(2,202)
$script:checks+=@{name='user return to another app at consent close is accepted';actual=$policy.AllowsForWindows(@(301,202),202,@(201,301));expected=$true}
$script:checks+=@{name='another app is not adopted to allow later target activation';actual=$policy.AllowsForWindows(@(301,202,201),201,@(201,301));expected=$false}
ConvertTo-Json -InputObject $checks -Compress
