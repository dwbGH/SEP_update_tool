function Test-DotNetDesktopRuntime {
    param([string]$MinVersion)
    $roots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $roots += (Join-Path $base 'dotnet\shared\Microsoft.WindowsDesktop.App') }
    }
    $found = @()
    foreach ($dir in $roots) {
        if (Test-Path $dir) {
            $found += Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        }
    }
    $best = $null
    foreach ($v in $found) {
        if ($null -eq $best) { $best = $v; continue }
        $cmp = Compare-NumericVersion $v $best
        if ($null -ne $cmp -and $cmp -gt 0) { $best = $v }
    }
    $ok = $false
    if ($best) {
        $cmp = Compare-NumericVersion $best $MinVersion
        if ($null -ne $cmp -and $cmp -ge 0) { $ok = $true }
    }
    return [pscustomobject]@{
        Present = ($found.Count -gt 0)
        Found   = $best
        Min     = $MinVersion
        Names   = $found
        Ok      = $ok
    }
}

function Test-PythonRuntime {
    param([string]$MinVersion)
    $versions = @()
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    $found = ''
    if ($null -ne $cmd) {
        try {
            $v = & $cmd.Source --version 2>&1
            $line = $v -join ''
            $m = [regex]::Match($line, '(\d+(\.\d+){1,3})')
            if ($m.Success) { $found = $m.Groups[1].Value; $versions += $found }
        } catch { }
    }
    $pyReg = @(
        'HKLM:\Software\Python\PythonCore\*\InstallPath',
        'HKLM:\Software\WOW6432Node\Python\PythonCore\*\InstallPath'
    )
    foreach ($rp in $pyReg) {
        foreach ($k in (Get-ChildItem $rp -ErrorAction SilentlyContinue)) {
            $v = $k.PSChildName
            if ($v -match '^\d') { $versions += $v }
        }
    }
    if ($MinVersion) {
        foreach ($v in @($versions)) {
            $cmp = Compare-NumericVersion $v $MinVersion
            if ($null -ne $cmp -and $cmp -ge 0) {
                return [pscustomobject]@{ Present = $true; Found = $v; Min = $MinVersion; Ok = $true }
            }
        }
        return [pscustomobject]@{ Present = ($versions.Count -gt 0); Found = ($versions -join ', '); Min = $MinVersion; Ok = $false }
    }
    return [pscustomobject]@{ Present = ($versions.Count -gt 0); Found = ($versions -join ', '); Min = ''; Ok = ($versions.Count -gt 0) }
}

function Test-ProductPrerequisites {
    param($Product)
    $deps = @()
    if ($null -ne $Product.PSObject.Properties['dependencies']) {
        foreach ($dep in @($Product.dependencies)) {
            $res = [pscustomobject]@{
                kind = $dep.kind
                minVersion = if ($null -ne $dep.PSObject.Properties['minVersion']) { [string]$dep.minVersion } else { '' }
                description = if ($null -ne $dep.PSObject.Properties['description']) { [string]$dep.description } else { '' }
                blocking = ConvertTo-Boolean $dep.blocking $true
                ok = $false
                found = ''
            }
            switch ($dep.kind) {
                'dotnetDesktop' {
                    $r = Test-DotNetDesktopRuntime $dep.minVersion
                    $res.ok = $r.Ok
                    $res.found = if ($r.Found) { $r.Found } else { 'not installed' }
                }
                'python' {
                    $r = Test-PythonRuntime $dep.minVersion
                    $res.ok = $r.Ok
                    $res.found = if ($r.Found) { $r.Found } else { 'not installed' }
                }
                default {
                    $res.ok = $true
                    $res.found = 'unsupported kind, skipped'
                }
            }
            $deps += $res
        }
    }
    return $deps
}