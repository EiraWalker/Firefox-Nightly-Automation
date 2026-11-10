# Snapshot comparison is independent of UIA providers and has no desktop side effects.
function Test-WorkspaceGuard {
    $setting=Get-Variable workspaceGuardEnabled -Scope Script -ErrorAction SilentlyContinue
    return ($null -ne $setting -and [bool]$setting.Value)
}

function Test-ObservationField($Observation,[string]$Name) {
    if($null -eq $Observation) { return $false }
    if($Observation -is [System.Collections.IDictionary]) { return $Observation.Contains($Name) }
    return ($null -ne $Observation.PSObject.Properties[$Name])
}
function Test-ObservationAvailable($Observation) {
    if($null -eq $Observation) { return $false }
    if(Test-ObservationField $Observation 'observationAvailable') { return [bool]$Observation.observationAvailable }
    return $true
}

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

# Canonical placement is opt-in per snapshot. Validate present fields before
# falling back for missing metadata so a malformed partial record is not trusted.
function Test-WindowPlacementRectangle($Rectangle) {
    if($Rectangle -isnot [System.Array] -or $Rectangle.Rank -ne 1 -or $Rectangle.Count -ne 4) { return $false }
    foreach($coordinate in $Rectangle) {
        $integer=($coordinate -is [sbyte] -or $coordinate -is [byte] -or $coordinate -is [int16] -or $coordinate -is [uint16] -or $coordinate -is [int32] -or $coordinate -is [uint32] -or $coordinate -is [int64] -or $coordinate -is [uint64])
        if(-not $integer -or $coordinate -lt [int32]::MinValue -or $coordinate -gt [int32]::MaxValue) { return $false }
    }
    return ($Rectangle[2] -gt $Rectangle[0] -and $Rectangle[3] -gt $Rectangle[1])
}

function Get-WindowPlacementStatus($Window) {
    $hasBounds=Test-ObservationField $Window 'normalBounds'
    $hasState=Test-ObservationField $Window 'restoredState'
    if($hasBounds -and -not (Test-WindowPlacementRectangle $Window.normalBounds)) { return 'invalid' }
    if($hasState -and ($Window.restoredState -isnot [string] -or $Window.restoredState -cnotin @('normal','maximized'))) { return 'invalid' }
    if(-not $hasBounds -or -not $hasState) { return 'missing' }
    if(-not (Test-ObservationField $Window 'bounds') -or -not (Test-WindowPlacementRectangle $Window.bounds) -or -not (Test-ObservationField $Window 'minimized') -or $Window.minimized -isnot [bool]) { return 'invalid' }
    return 'valid'
}

function Compare-DesktopSnapshot($Before,$After) {
    $previous=@{}; $current=@{}
    foreach($window in $Before.windows) { $previous[[string]$window.hwnd]=$window }
    foreach($window in $After.windows) { $current[[string]$window.hwnd]=$window }
    $identity=($previous.Count -eq $current.Count)
    foreach($key in $previous.Keys) { if(-not $current.ContainsKey($key)) { $identity=$false } }
    $bounds=$identity; $minimized=$identity; $canonical=$identity; $selection=$identity; $provider=$identity
    $positionChanged=$false; $minimizedChanged=$false; $selectionChanged=$false; $placementInvalid=$false
    foreach($key in $previous.Keys) {
        if(-not $current.ContainsKey($key)) { continue }
        $left=$previous[$key]; $right=$current[$key]
        $hasRawBounds=((Test-ObservationField $left 'bounds') -and (Test-ObservationField $right 'bounds'))
        $hasMinimized=((Test-ObservationField $left 'minimized') -and (Test-ObservationField $right 'minimized'))
        $sameBounds=($hasRawBounds -and ($left.bounds -join ',') -ceq ($right.bounds -join ','))
        $sameMinimized=($hasMinimized -and $left.minimized -eq $right.minimized)
        if(-not $sameBounds) { $bounds=$false }
        if(-not $sameMinimized) { $minimized=$false }
        $leftPlacement=Get-WindowPlacementStatus $left
        $rightPlacement=Get-WindowPlacementStatus $right
        if($leftPlacement -eq 'invalid' -or $rightPlacement -eq 'invalid') {
            $canonical=$false; $placementInvalid=$true
        } elseif($leftPlacement -eq 'valid' -and $rightPlacement -eq 'valid') {
            $samePlacement=(($left.normalBounds -join ',') -ceq ($right.normalBounds -join ',') -and $left.restoredState -ceq $right.restoredState)
            if(-not $samePlacement -or (-not $left.minimized -and -not $right.minimized -and -not $sameBounds)) { $canonical=$false; $positionChanged=$true }
        } else {
            # Retain the legacy fail-closed decision, but do not claim a change
            # was observed when either snapshot simply omitted a raw field.
            if(-not $sameBounds) { $canonical=$false; if($hasRawBounds) { $positionChanged=$true } }
            if(-not $sameMinimized) { $canonical=$false; if($hasMinimized) { $minimizedChanged=$true } }
        }
        if(-not (Test-ObservationAvailable $left) -or -not (Test-ObservationAvailable $right)) { $selection=$false; $provider=$false; continue }
        $sameTab=if($left.selectedTabIdentityKind -eq 'automation-id' -and $right.selectedTabIdentityKind -eq 'automation-id') {
            $left.selectedTabKey -ceq $right.selectedTabKey
        } else {
            # A provider may temporarily omit AutomationId during reconstruction.
            # Compare the structural selection when either snapshot lacks a unique ID.
            $left.selectedTabPosition -eq $right.selectedTabPosition
        }
        if(-not $sameTab) { $selection=$false; $selectionChanged=$true }
        if(-not $left.selectedTab -or -not $right.selectedTab -or $left.selectedTab -cne $right.selectedTab) { $provider=$false }
    }
    $available=((Test-ObservationAvailable $Before) -and (Test-ObservationAvailable $After) -and @($Before.windows | Where-Object { -not (Test-ObservationAvailable $_) }).Count -eq 0 -and @($After.windows | Where-Object { -not (Test-ObservationAvailable $_) }).Count -eq 0)
    $reasons=@()
    if(-not $available) { $reasons+='observation-unavailable' }
    if($placementInvalid) { $reasons+='window-placement-invalid' }
    if(-not $identity) { $reasons+='window-set' }
    if($identity -and $positionChanged) { $reasons+='window-position' }
    if($identity -and $minimizedChanged) { $reasons+='window-minimized' }
    if($identity -and $selectionChanged) { $reasons+='tab-selection' }
    return @{
        # Selection remains observable, but is not a window/geometry safety gate.
        windowsWithinControlPolicy=($available -and $identity -and $canonical)
        windowsStable=($available -and $identity -and $canonical -and $selection)
        windowIdentityStable=$identity
        windowGeometryStable=($identity -and $bounds -and $minimized)
        canonicalGeometryStable=($identity -and $canonical)
        minimizedStateStable=($identity -and $minimized)
        selectedTabsStable=$selection
        tabProviderIdentityStable=$provider
        reasons=@($reasons)
    }
}
