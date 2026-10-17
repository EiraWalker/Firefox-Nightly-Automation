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
ConvertTo-Json -InputObject $checks -Compress
