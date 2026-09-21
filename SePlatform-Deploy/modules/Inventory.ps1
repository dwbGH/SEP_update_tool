function Get-SePlatformInventory {
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $result = @()
    foreach ($rp in $regPaths) {
        $items = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            $displayName = [string]$i.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            $inst = [pscustomobject]@{
                DisplayName        = $displayName
                DisplayVersion     = [string]$i.DisplayVersion
                Publisher          = [string]$i.Publisher
                InstallLocation    = [string]$i.InstallLocation
                UninstallString    = [string]$i.UninstallString
                QuietUninstallString = [string]$i.QuietUninstallString
                WindowsInstaller   = $i.WindowsInstaller
                PSChildName        = [string]$i.PSChildName
                RegistryPath       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
                ProductCode        = ''
            }
            if ($inst.WindowsInstaller -eq 1) {
                $inst.ProductCode = $inst.PSChildName
                $inst.RegistryPath = $rp -replace '\*$', ''
            }
            $result += $inst
        }
    }
    return ,$result
}

function Find-InstalledByPattern {
    param([string]$Pattern, [object[]]$Inventory)
    $rx = $Pattern
    $hits = @($Inventory | Where-Object {
        try { $_.DisplayName -match $rx } catch { $false }
    })
    return ,$hits
}

function ConvertTo-InstalledDisplayVersion {
    param($Inst)
    if ($null -eq $Inst) { return '' }
    $rich = Get-RichVersion $Inst.DisplayName
    if ($rich) { return $rich }
    return [string]$Inst.DisplayVersion
}