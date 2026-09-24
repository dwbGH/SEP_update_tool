$script:EXIT_OK = 0
$script:EXIT_ERRORS = 1
$script:EXIT_ABORTED = 2
$script:EXIT_PREREQ = 3
$script:EXIT_BAD_PARAMS = 4

$script:Deployment = @{
    StartTime     = $null
    SessionDir    = $null
    LogFile       = $null
    ReportFile    = $null
    ArchivePath   = $null
    ArchiveName   = $null
    Manifest      = $null
    Config        = $null
    Locale        = @()
    TempRoot      = $null
    MsiTempDir    = $null
    Inventory     = @()
    Products      = @()
    Results       = @()
    Actions       = @()
    CountUpdated  = 0
    CountInstalled = 0
    CountUninstalled = 0
    CountSkipped  = 0
    CountFailed   = 0
    CountOk       = 0
    AbortRequired = $false
}

function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MachineFriendlyOs {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $osCaption = $os.Caption
        $bit = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITECTURE -eq 'x86_64') { 'x64' } else { 'x86' }
        return ($osCaption + ' ' + $bit)
    } catch {
        return ($env:OS + ' ' + $env:PROCESSOR_ARCHITECTURE)
    }
}

function ConvertTo-ResolvedPath {
    param([string]$Path)
    $result = $Path
    if ($result -match '\$env:') {
        $m = [regex]::Match($result, '\$env:(\w+)')
        if ($m.Success) {
            $envName = $m.Groups[1].Value
            $envValue = [Environment]::GetEnvironmentVariable($envName)
            if ($envValue) { $result = $result.Replace($m.Value, $envValue) }
        }
    }
    if ($result -match '^\$env:\((\w+)\)') {
        $result = [Environment]::GetEnvironmentVariable($Matches[1]) + $result.Substring($Matches[0].Length)
    }
    return $result
}

function Expand-ZipEntry {
    param([string]$ZipPath, [string]$EntryName, [string]$DestinationPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName }
        if ($null -eq $entry) {
            $entry = $zip.Entries | Where-Object { $_.FullName -replace '/', '\' -eq $EntryName }
        }
        if ($null -eq $entry) { throw ('ZIP entry not found: ' + $EntryName) }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath, $true)
    } finally {
        $zip.Dispose()
    }
}

function Invoke-MsiExec {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$LogPath,
        [int]$TimeoutSeconds = 900
    )
    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add('/' + $Operation)
    $argsList.Add('"' + $Target + '"')
    $argsList.Add('/qn')
    $argsList.Add('/norestart')
    if ($LogPath) {
        $argsList.Add('/l*v')
        $argsList.Add('"' + $LogPath + '"')
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'msiexec.exe'
    $psi.Arguments = ($argsList -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ ExitCode = 9998; TimedOut = $false; Error = $_.Exception.Message }
    }
    if ($null -eq $proc) {
        return @{ ExitCode = 9998; TimedOut = $false; Error = 'Failed to start msiexec.exe' }
    }
    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        return @{ ExitCode = 9999; TimedOut = $true; Error = 'msiexec timed out and was killed' }
    }
    return @{ ExitCode = $proc.ExitCode; TimedOut = $false; Error = '' }
}

function ConvertTo-Boolean {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = [string]$Value
    if ($s -match '(?i)^(true|yes|1|on)$') { return $true }
    if ($s -match '(?i)^(false|no|0|off)$') { return $false }
    return $Default
}