function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw ('Config file not found: ' + $Path)
    }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    return $cfg
}

function Load-Manifest {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw ('Manifest file not found: ' + $Path)
    }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $manifest = $raw | ConvertFrom-Json
    if ($null -eq $manifest.products -or @($manifest.products).Count -eq 0) {
        throw ('Manifest contains no products')
    }
    return $manifest
}

function Validate-ManifestProduct {
    param($p)
    $errors = @()
    if ([string]::IsNullOrWhiteSpace($p.id)) { $errors += 'missing id' }
    if ([string]::IsNullOrWhiteSpace($p.installerPattern)) { $errors += $p.id + ': missing installerPattern' }
    if ([string]::IsNullOrWhiteSpace($p.matchPattern)) { $errors += $p.id + ': missing matchPattern' }
    try { [regex]::IsMatch('', [string]$p.matchPattern) } catch {
        $errors += $p.id + ': invalid matchPattern regex'
    }
    return $errors
}

function Get-ProductById {
    param([string]$Id)
    foreach ($p in $script:Deployment.Manifest.products) {
        if ($p.id -eq $Id) { return $p }
    }
    return $null
}