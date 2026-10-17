# Snapshot comparison is independent of UIA providers and has no desktop side effects.
function Get-TabSelection([object[]]$Tabs) {
    if($Tabs.Count -eq 0) { throw 'F_OBSERVER_UNAVAILABLE' }
    $selected=@(0..($Tabs.Count-1) | Where-Object { $Tabs[$_].selected })
    if($selected.Count -ne 1) { throw 'F_OBSERVER_UNAVAILABLE' }
    $index=$selected[0]
    $id=[string]$Tabs[$index].automationId
    $unique=(-not [string]::IsNullOrWhiteSpace($id) -and @($Tabs | Where-Object { $_.automationId -ceq $id }).Count -eq 1)
    return @{
        key=$(if($unique){'id:'+$id}else{'position:'+$index})
        kind=$(if($unique){'automation-id'}else{'tab-position'})
        position=$index
        runtimeId=[string]$Tabs[$index].runtimeId
    }
}

function Compare-DesktopSnapshot($Before,$After) {
    $previous=@{}; $current=@{}
    foreach($window in $Before.windows) { $previous[[string]$window.hwnd]=$window }
    foreach($window in $After.windows) { $current[[string]$window.hwnd]=$window }
    $identity=($previous.Count -eq $current.Count)
    foreach($key in $previous.Keys) { if(-not $current.ContainsKey($key)) { $identity=$false } }
    $bounds=$identity; $minimized=$identity; $selection=$identity; $provider=$identity
    foreach($key in $previous.Keys) {
        if(-not $current.ContainsKey($key)) { continue }
        $left=$previous[$key]; $right=$current[$key]
        if(($left.bounds -join ',') -cne ($right.bounds -join ',')) { $bounds=$false }
        if($left.minimized -ne $right.minimized) { $minimized=$false }
        $sameTab=if($left.selectedTabIdentityKind -eq 'automation-id' -and $right.selectedTabIdentityKind -eq 'automation-id') {
            $left.selectedTabKey -ceq $right.selectedTabKey
        } else {
            # A provider may temporarily omit AutomationId during reconstruction.
            # Compare the structural selection when either snapshot lacks a unique ID.
            $left.selectedTabPosition -eq $right.selectedTabPosition
        }
        if(-not $sameTab) { $selection=$false }
        if(-not $left.selectedTab -or -not $right.selectedTab -or $left.selectedTab -cne $right.selectedTab) { $provider=$false }
    }
    $reasons=@()
    if(-not $identity) { $reasons+='window-set' }
    if($identity -and -not $bounds) { $reasons+='window-position' }
    if($identity -and -not $minimized) { $reasons+='window-minimized' }
    if($identity -and -not $selection) { $reasons+='tab-selection' }
    return @{
        windowsStable=($identity -and $bounds -and $minimized -and $selection)
        windowIdentityStable=$identity
        windowGeometryStable=($identity -and $bounds -and $minimized)
        selectedTabsStable=$selection
        tabProviderIdentityStable=$provider
        reasons=@($reasons)
    }
}
