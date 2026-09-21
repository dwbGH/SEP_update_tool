function Get-VersionParts {
    param([string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }
    $s = $VersionString.Trim()
    $s = $s.Trim('"', "'", 'v', 'V')
    $baseMatch = [regex]::Match($s, '\d+(?:\.\d+){1,3}')
    if (-not $baseMatch.Success) { return $null }
    $parts = @()
    foreach ($seg in $baseMatch.Value.Split('.')) { $parts += [int]$seg }
    $tailIndex = $baseMatch.Index + $baseMatch.Length
    $tail = $s.Substring($tailIndex)
    if ($tail -match '\+') {
        $tail = $tail.Substring($tail.IndexOf('+'))
        $tailNums = [regex]::Matches($tail, '\d+')
        foreach ($m in $tailNums) { $parts += [int]$m.Value }
    }
    if ($parts.Count -gt 6) { $parts = $parts | Select-Object -First 6 }
    while ($parts.Count -lt 6) { $parts += 0 }
    return $parts
}

function Compare-ProductVersion {
    param([string]$Left, [string]$Right)
    $lp = Get-VersionParts $Left
    $rp = Get-VersionParts $Right
    if ($null -eq $lp -or $null -eq $rp) {
        if ($Left -eq $Right) { return 0 }
        return $null
    }
    for ($i = 0; $i -lt 4; $i++) {
        if ($lp[$i] -lt $rp[$i]) { return -1 }
        if ($lp[$i] -gt $rp[$i]) { return 1 }
    }
    return 0
}

function Get-RichVersion {
    param([string]$Name)
    $m = [regex]::Match($Name, '\d+(?:\.\d+){1,3}(?:\+\S+)?')
    if ($m.Success) { return $m.Value.Trim() }
    return ''
}

function Get-ExtractedRevision {
    param([string]$VersionString)
    $parts = Get-VersionParts $VersionString
    if ($null -eq $parts) { return 0 }
    $rev = $parts[4]
    if ($parts[5] -gt 0) { $rev = $rev * 1000000 + $parts[5] }
    return $rev
}

function Compare-NumericVersion {
    param([string]$Left, [string]$Right)
    $l = Get-VersionParts $Left
    $r = Get-VersionParts $Right
    if ($null -eq $l -or $null -eq $r) {
        if ($Left -eq $Right) { return 0 }
        return $null
    }
    for ($i = 0; $i -lt 6; $i++) {
        if ($l[$i] -lt $r[$i]) { return -1 }
        if ($l[$i] -gt $r[$i]) { return 1 }
    }
    return 0
}