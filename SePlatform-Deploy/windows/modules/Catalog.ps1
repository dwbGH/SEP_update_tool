function Get-ZipMsiEntries {
    param([string]$ZipPath, [string]$IncludeGlob = '*.msi')
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $result = @()
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -match '/$') { continue }
            $name = $e.FullName.Split('/')[-1]
            if (ConvertTo-MatchSimplifiedGlob -Value $name -Pattern $IncludeGlob) {
                $result += [pscustomobject]@{
                    Name     = $name
                    FullName = $e.FullName
                    Length   = $e.Length
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
    return $result
}

function ConvertTo-MatchSimplifiedGlob {
    param([string]$Value, [string]$Pattern)
    $rx = '^' + [regex]::Escape($Pattern).Replace('\*', '.*').Replace('\?', '.') + '$'
    return ($Value -match $rx)
}

function ConvertTo-LocaleTokenRegex {
    param([string]$Name, [string]$Locale)
    $lower = $Locale.ToLowerInvariant()
    if ($lower -eq 'ru') { $cands = @('ru', 'ru_ru') }
    elseif ($lower -eq 'en') { $cands = @('en', 'en_us') }
    else { $cands = @($lower) }
    $n = ($Name -replace '(?i)(\.msi|\.deb|\.rpm)$', '')
    foreach ($c in $cands) {
        $esc = [regex]::Escape($c)
        if ($n -match ('(?i)(?<![a-z0-9])' + $esc + '(?![a-z0-9])')) { return $true }
    }
    return $false
}

function ConvertTo-ContainsArchToken {
    param([string]$Name, [string]$Arch)
    $n = ($Name -replace '(?i)\.msi$', '')
    if ($Arch -eq 'x64') { return ($n -match '(?i)x(?:-?_?|[- ()]*)64|amd64') }
    if ($Arch -eq 'x86') { return ($n -match '(?i)(^|[._ ()-])x86([._ ()-]|$)') }
    return $false
}

function Select-CatalogCandidate {
    param($Product, [object[]]$ZipEntries, [string[]]$LocalePreference, [string]$PreferArch)
    $pattern = [string]$Product.installerPattern
    $cands = @($ZipEntries | Where-Object { ConvertTo-MatchSimplifiedGlob -Value $_.Name -Pattern $pattern })
    if ($cands.Count -eq 0) { return $null }

    $archHits = @($cands | Where-Object { ConvertTo-ContainsArchToken -Name $_.Name -Arch $PreferArch })
    if ($archHits.Count -gt 0) { $cands = $archHits }

    $localeOk = $false
    foreach ($pref in $LocalePreference) {
        $hits = @($cands | Where-Object { ConvertTo-LocaleTokenRegex -Name $_.Name -Locale $pref })
        if ($hits.Count -gt 0) {
            $cands = $hits
            $localeOk = $true
            break
        }
    }

    $scored = @()
    foreach ($c in $cands) {
        $parts = Get-VersionParts $c.Name
        $scored += [pscustomobject]@{
            Name = $c.Name
            FullName = $c.FullName
            Length = $c.Length
            Score = if ($null -ne $parts) { $parts[0] * 100000000 + $parts[1] * 1000000 + $parts[2] * 10000 + $parts[3] } else { 0 }
        }
    }
    $best = $scored | Sort-Object Score, Name -Descending | Select-Object -First 1
    return $best
}

function Read-MsiProperties {
    param([string]$MsiPath)
    $props = @{}
    $installer = $null
    $db = $null
    $view = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT Property, Value FROM Property'))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        while ($true) {
            try {
                $row = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            } catch {
                break
            }
            if ($null -eq $row) { break }
            $k = $row.GetType().InvokeMember('StringData', 'GetProperty', $null, $row, @(1))
            $v = $row.GetType().InvokeMember('StringData', 'GetProperty', $null, $row, @(2))
            if ($null -ne $k -and -not $props.ContainsKey($k)) { $props[$k] = $v }
        }
    } catch {
        $props['_ReadError'] = $_.Exception.Message
    }
    if ($null -ne $view) { try { $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null } catch { } }
    if ($null -ne $db) {
        try { $installer.GetType().InvokeMember('CloseDatabase', 'InvokeMethod', $null, $installer, @($db)) | Out-Null } catch { }
    }
    if ($null -ne $installer) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) } catch { } }
    $summary = [pscustomobject]@{
        ProductName    = if ($props.ContainsKey('ProductName')) { $props['ProductName'] } else { '' }
        ProductVersion = if ($props.ContainsKey('ProductVersion')) { $props['ProductVersion'] } else { '' }
        ProductCode    = if ($props.ContainsKey('ProductCode')) { $props['ProductCode'] } else { '' }
        UpgradeCode    = if ($props.ContainsKey('UpgradeCode')) { $props['UpgradeCode'] } else { '' }
        Manufacturer   = if ($props.ContainsKey('Manufacturer')) { $props['Manufacturer'] } else { '' }
        ReadError      = if ($props.ContainsKey('_ReadError')) { $props['_ReadError'] } else { '' }
    }
    return $summary
}