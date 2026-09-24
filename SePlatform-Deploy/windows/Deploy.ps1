param(
    [string]$Archive = '',
    [string]$Config = '.\config.json',
    [string]$Manifest = '.\manifest.json',
    [string]$LogPath = '',
    [switch]$KeepTemp,
    [switch]$WhatIf,
    [switch]$NonInteractive,
    [switch]$AutoApprove,
    [switch]$Uninstall,
    [switch]$UpdateOnly,
    [switch]$ServerCopies,
    [string]$Locale = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }

foreach ($m in @('Core.ps1', 'Logging.ps1', 'Versioning.ps1', 'Manifest.ps1', 'Catalog.ps1', 'Inventory.ps1', 'Dependencies.ps1', 'Installer.ps1', 'Uninstaller.ps1', 'Verification.ps1', 'UI.ps1', 'ServerCopies.ps1')) {
    $mod = Join-Path $scriptRoot ('modules\' + $m)
    if (-not (Test-Path $mod)) {
        Write-Host ('ERROR: Required module not found: ' + $mod) -ForegroundColor Red
        exit $script:EXIT_BAD_PARAMS
    }
    . $mod
}

$script:Deployment.WhatIf = [bool]$WhatIf
$script:Deployment.NonInteractive = [bool]$NonInteractive
$script:Deployment.AutoApprove = [bool]$AutoApprove
$script:Deployment.Uninstall = [bool]$Uninstall
$script:Deployment.UpdateOnly = [bool]$UpdateOnly
$script:Deployment.ServerCopies = [bool]$ServerCopies

function Resolve-ScriptRelativePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $Path))
}

function Get-EffectiveLocalePreference {
    param($Product)
    if ($script:Locale) { return @($script:Locale) }
    if ($null -ne $script:Deployment.Config.PSObject.Properties['localePreference']) {
        return @($script:Deployment.Config.localePreference)
    }
    if ($null -ne $Product.PSObject.Properties['localePreference']) {
        return @($Product.localePreference)
    }
    return @('ru_RU', 'ru', 'en_US', 'en')
}

try {
    $configPath = Resolve-ScriptRelativePath $Config
    $manifestPath = Resolve-ScriptRelativePath $Manifest

    if (-not $script:Deployment.WhatIf) {
        if (-not (Test-IsElevated)) {
            Write-Host ''
            Write-Host 'ERROR: This deployment requires Administrator privileges.' -ForegroundColor Red
            Write-Host 'Please restart PowerShell as Administrator and run the tool again.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The exact same command:'
            $cmdLine = ('.\\Deploy.ps1 -Archive "' + $Archive + '"')
            if ($WhatIf) { $cmdLine += ' -WhatIf' }
            if ($AutoApprove) { $cmdLine += ' -AutoApprove' }
            if ($KeepTemp) { $cmdLine += ' -KeepTemp' }
            Write-Host ('  ' + $cmdLine)
            Write-Host ''
            exit $script:EXIT_BAD_PARAMS
        }
    }

    $cfg = Load-Config $configPath
    $script:Deployment.Config = $cfg

    $manifestObj = Load-Manifest $manifestPath
    $script:Deployment.Manifest = $manifestObj

    $interactiveStartup = ($script:Deployment.Uninstall -eq $false) -and
        ($script:Deployment.UpdateOnly -eq $false) -and
        ($script:Deployment.ServerCopies -eq $false) -and
        ($script:Deployment.NonInteractive -eq $false) -and
        ($script:Deployment.WhatIf -eq $false) -and
        (-not $Archive)
    if ($interactiveStartup) {
        $startupArchive = ''
        if ($cfg.PSObject.Properties['defaultArchive'] -and $cfg.defaultArchive) {
            $startupArchive = [string]$cfg.defaultArchive
        }
        $choice = Ask-StartupMode -DefaultArchive $startupArchive
        if ($choice.Mode -eq 'EXIT') {
            Write-Host 'Exiting.' -ForegroundColor Yellow
            exit $script:EXIT_ABORTED
        }
        if ($choice.Mode -eq 'SERVER_COPIES') {
            $script:Deployment.ServerCopies = $true
            $Archive = ''
        } else {
            $Archive = $choice.Archive
        }
    }

    if ($Script:Deployment.ServerCopies) {
        $baseLogRoot = if ($LogPath) { $LogPath } else { if ($cfg.PSObject.Properties['logRoot']) { [string]$cfg.logRoot } else { 'C:\ProgramData\SePlatform\Deployment' } }
        $null = New-LogSession -BaseRoot $baseLogRoot -ArchiveName 'ServerCopies' -WhatIf:$script:Deployment.WhatIf -NonInteractive:$script:Deployment.NonInteractive
        Write-Log 'Mode: SERVER_COPIES'
        Manage-AdditionalServerCopies
        $script:Deployment.Results = @($script:Deployment.Products)
        $hasFailed = $script:Deployment.CountFailed -gt 0
        $exit = if ($hasFailed) { $script:EXIT_ERRORS } else { $script:EXIT_OK }
        $resultName = if ($hasFailed) { 'COMPLETED_WITH_ERRORS' } else { 'SUCCESS' }
        $null = Save-Report -ExitCode $exit -Result $resultName
        Show-Summary -Results $script:Deployment.Results -ExitCode $exit
        if ($script:ServerCopiesState.Results.Count -gt 0) {
            Write-Host 'Server copies actions:'
            Write-Host ''
            foreach ($r in $script:ServerCopiesState.Results) {
                $marker = if ($r.Status -eq 'OK') { '[OK]' } else { '[INFO]' }
                if ($r.Status -eq 'PENDING') { $marker = '[PLANNED]' }
                Write-Host ($marker + ' ' + $r.Action + ' ' + $r.FolderName + '  service=' + $r.ServiceName)
            }
            Write-Host ''
        }
        Write-Host ('Report: ' + $script:Deployment.ReportFile)
        exit $exit
    }

    $archivePath = $Archive
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        if ($cfg.PSObject.Properties['defaultArchive'] -and $cfg.defaultArchive) {
            $archivePath = [string]$cfg.defaultArchive
        }
    }
    $script:Locale = $Locale
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        Write-Host 'ERROR: Archive path was not provided. Use -Archive "path_to_zip".' -ForegroundColor Red
        exit $script:EXIT_BAD_PARAMS
    }
    $archivePath = ConvertTo-ResolvedPath $archivePath
    if (-not (Test-Path $archivePath)) {
        Write-Host ('ERROR: Archive not found: ' + $archivePath) -ForegroundColor Red
        exit $script:EXIT_BAD_PARAMS
    }
    $script:Deployment.ArchivePath = $archivePath
    $script:Deployment.ArchiveName = Split-Path -Leaf $archivePath
    if ($cfg.PSObject.Properties['tempRoot']) { $script:Deployment.TempRoot = ConvertTo-ResolvedPath ([string]$cfg.tempRoot) }
    else { $script:Deployment.TempRoot = ConvertTo-ResolvedPath '$env:TEMP\SePlatform-Deploy' }

    $baseLogRoot = if ($LogPath) { $LogPath } else { if ($cfg.PSObject.Properties['logRoot']) { [string]$cfg.logRoot } else { 'C:\ProgramData\SePlatform\Deployment' } }
    $null = New-LogSession -BaseRoot $baseLogRoot -ArchiveName $script:Deployment.ArchiveName -WhatIf:$script:Deployment.WhatIf -NonInteractive:$script:Deployment.NonInteractive

    $tempSession = Join-Path $script:Deployment.TempRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    if (-not (Test-Path $tempSession)) { New-Item -ItemType Directory -Path $tempSession -Force | Out-Null }
    $script:Deployment.MsiTempDir = Join-Path $tempSession 'msi'
    New-Item -ItemType Directory -Path $script:Deployment.MsiTempDir -Force | Out-Null

    $keepTemp = if ($KeepTemp) { $true } else { if ($cfg.PSObject.Properties['keepTempOnError']) { ConvertTo-Boolean $cfg.keepTempOnError } else { $false } }
    $cleanupOnSuccess = if ($cfg.PSObject.Properties['cleanupTempOnSuccess']) { ConvertTo-Boolean $cfg.cleanupTempOnSuccess $true } else { $true }
    $msiTimeout = if ($cfg.PSObject.Properties['msiexecTimeoutSeconds']) { [int]$cfg.msiexecTimeoutSeconds } else { 900 }
    $uninstallTimeout = if ($cfg.PSObject.Properties['uninstallTimeoutSeconds']) { [int]$cfg.uninstallTimeoutSeconds } else { 600 }
    $installTimeout = if ($cfg.PSObject.Properties['installTimeoutSeconds']) { [int]$cfg.installTimeoutSeconds } else { 900 }
    $continueOnError = if ($cfg.PSObject.Properties['continueOnComponentError']) { ConvertTo-Boolean $cfg.continueOnComponentError $true } else { $true }

    $warnOnNewer = $true
    if ($cfg.PSObject.Properties['warnOnNewerVersion']) { $warnOnNewer = ConvertTo-Boolean $cfg.warnOnNewerVersion $true }

    if ($script:Deployment.Uninstall) {
        Write-Log 'Mode: UNINSTALL'
    } elseif ($script:Deployment.UpdateOnly) {
        Write-Log 'Mode: UPDATE_ONLY'
    } else {
        Write-Log 'Mode: default (install and update)'
    }

    Write-Log ('Deployment started for archive: ' + $archivePath)
    Write-Log ('Scanning ZIP for whitelisted MSI packages...')

    $preferArch = 'x64'
    if ($cfg.PSObject.Properties['preferArch']) { $preferArch = [string]$cfg.preferArch }
    $zipEntries = Get-ZipMsiEntries -ZipPath $archivePath -IncludeGlob '*.msi'
    Write-Log ('ZIP total MSI entries: ' + $zipEntries.Count)

    $actions = @()
    foreach ($prod in @($manifestObj.products)) {
        $pattern = [string]$prod.installerPattern
        $id = [string]$prod.id
        $display = if ($prod.PSObject.Properties['displayName'] -and $prod.displayName) { [string]$prod.displayName } else { $id }
        $localePrefs = Get-EffectiveLocalePreference $prod

        $candidate = Select-CatalogCandidate -Product $prod -ZipEntries $zipEntries -LocalePreference $localePrefs -PreferArch $preferArch

        $action = [pscustomobject]@{
            Id              = $id
            DisplayName     = $display
            Group           = if ($prod.PSObject.Properties['group']) { [string]$prod.group } else { '' }
            Required        = ConvertTo-Boolean $prod.required $false
            Order           = if ($null -ne $prod.PSObject.Properties['order']) { [int]$prod.order } else { 500 }
            Status          = 'UNKNOWN'
            OldVersion      = ''
            NewVersion      = ''
            InstalledVersion = ''
            Installed       = $null
            Candidate       = $candidate
            MsiPath         = $null
            MsiProps        = $null
            Services        = @()
            Processes       = @()
            Dependencies    = @()
            DependencyIssues = @()
            HasBlockingDependency = $false
            Error           = ''
            InstallExitCode = $null
            UninstallExitCode = $null
            Verified        = $false
        }
        if ($prod.PSObject.Properties['services']) { $action.Services = @($prod.services) }
        if ($prod.PSObject.Properties['processes']) { $action.Processes = @($prod.processes) }

        if ($null -eq $candidate) {
            $action.Status = 'NO_MSI'
            $action.Error = 'No matching MSI in archive (pattern: ' + $pattern + ')'
            $actions += $action
            Write-Host ('[WARN] ' + $display + ': no whitelisted MSI found in archive') -ForegroundColor Yellow
            continue
        }
        $destMsi = Join-Path $script:Deployment.MsiTempDir $candidate.Name
        try {
            Expand-ZipEntry -ZipPath $archivePath -EntryName $candidate.FullName -DestinationPath $destMsi
            $action.MsiPath = $destMsi
        } catch {
            $action.Status = 'NO_MSI'
            $action.Error = 'Failed to extract MSI: ' + $_.Exception.Message
            $actions += $action
            Write-Host ('[WARN] ' + $display + ': failed to extract MSI - ' + $_.Exception.Message) -ForegroundColor Yellow
            continue
        }
        $props = Read-MsiProperties -MsiPath $destMsi
        $action.MsiProps = $props
        if ($props.ReadError) {
            Write-Host ('[WARN] ' + $display + ': could not read MSI properties, using filename version') -ForegroundColor Yellow
        }
        $action.NewVersion = $props.ProductVersion
        if (-not $action.NewVersion) { $action.NewVersion = Get-RichVersion $candidate.Name }
        $actions += $action
    }

    Write-Log ('Extracted MSIs: ' + $actions.Count)

    $inv = Get-SePlatformInventory
    $script:Deployment.Inventory = $inv
    Write-Log ('Registry inventory entries scanned: ' + $inv.Count)

    foreach ($a in $actions) {
        if ($a.Status -eq 'NO_MSI') { continue }
        $prod = Get-ProductById $a.Id
        $hits = @(Find-InstalledByPattern -Pattern ([string]$prod.matchPattern) -Inventory $inv)
        if ($hits.Count -gt 1) {
            Write-Host ('[WARN] ' + $a.DisplayName + ': multiple matching installed entries, first one used') -ForegroundColor Yellow
        }
        if ($hits.Count -gt 0) {
            $inst = $hits[0]
            $a.Installed = $inst
            $a.InstalledVersion = ConvertTo-InstalledDisplayVersion $inst
            $a.OldVersion = $a.InstalledVersion
            $cmp = Compare-ProductVersion $a.InstalledVersion $a.NewVersion
            if ($null -eq $cmp) {
                $a.Status = 'UPDATE'
            } elseif ($cmp -lt 0) {
                $a.Status = 'UPDATE'
            } elseif ($cmp -eq 0) {
                $a.Status = 'OK'
                $a.InstalledVersion = $a.InstalledVersion
            } else {
                $a.Status = 'SKIP_NEWER'
                $a.Error = 'Installed version is newer than the archive'
            }
        } else {
            $a.Status = 'MISSING'
        }
    }

    foreach ($a in @($actions | Where-Object { $_.Status -in @('UPDATE', 'MISSING') })) {
        $prod = Get-ProductById $a.Id
        $deps = Test-ProductPrerequisites $prod
        $a.Dependencies = $deps
        $issues = @()
        $hasBlocking = $false
        foreach ($d in $deps) {
            if (-not $d.ok) {
                $issues += ($d.description + ' not satisfied (found: ' + $d.found + ', min: ' + $d.min + ')')
                if ($d.blocking) { $hasBlocking = $true }
            }
        }
        $a.DependencyIssues = $issues
        $a.HasBlockingDependency = $hasBlocking
        if ($hasBlocking) {
            $a.Status = 'BLOCKED'
            $a.Error = 'Prerequisites not satisfied'
        }
    }

    $script:Deployment.Products = $actions

    Write-Banner 'SePlatform Deployment Tool'
    Show-Plan -Actions $actions

    if ($script:Deployment.WhatIf) {
        Write-Log 'Dry run: no changes were made'
        $null = Save-Report -ExitCode $script:EXIT_OK -Result 'DRY_RUN'
        Write-Host ''
        Write-Host ('Logs: ' + $script:Deployment.SessionDir)
        exit $script:EXIT_OK
    }

    if ($script:Deployment.Uninstall) { $mode = 'UNINSTALL' }
    elseif ($script:Deployment.UpdateOnly) { $mode = 'UPDATE' }
    elseif ($script:Deployment.AutoApprove -or $script:Deployment.NonInteractive) { $mode = 'INSTALL' }
    else {
        $mode = Ask-DeployMode
        if ($mode -eq 'EXIT') {
            Write-Log 'Deployment cancelled by user'
            $forReport = @($actions | ForEach-Object { $_.Status = 'ABORTED'; $_ })
            $null = Save-Report -ExitCode $script:EXIT_ABORTED -Result 'ABORTED'
            Show-Summary -Results $forReport -ExitCode $script:EXIT_ABORTED
            exit $script:EXIT_ABORTED
        }
    }

    if ($mode -eq 'UNINSTALL') {
        $targets = @($actions | Where-Object { $null -ne $_.Installed -and $_.Installed.ProductCode -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}\}$' } | Sort-Object Order, Id)
        if ($targets.Count -eq 0) {
            Write-Log 'No installed components available for uninstall'
            $script:Deployment.Results = @(New-ReportResults -Actions $actions)
            $null = Save-Report -ExitCode $script:EXIT_OK -Result 'SUCCESS'
            Show-Summary -Results $script:Deployment.Results -ExitCode $script:EXIT_OK
            exit $script:EXIT_OK
        }
        $selectedTargets = @($targets)
        if (-not ($script:Deployment.AutoApprove -or $script:Deployment.NonInteractive)) {
            $selectedTargets = @(Ask-NumberedSelection -Items $targets -Title 'Components to uninstall')
            if ($selectedTargets.Count -eq 0) {
                Write-Log 'No components selected for uninstall'
                $script:Deployment.Results = @(New-ReportResults -Actions $actions)
                $null = Save-Report -ExitCode $script:EXIT_ABORTED -Result 'ABORTED'
                Show-Summary -Results $script:Deployment.Results -ExitCode $script:EXIT_ABORTED
                exit $script:EXIT_ABORTED
            }
            Write-Host '================================'
            $confirmResult = Ask-YesNo -Prompt 'Uninstall selected components'
            Write-Host ''
            if (-not $confirmResult) {
                Write-Log 'Uninstall aborted by user'
                $script:Deployment.Results = @(New-ReportResults -Actions $actions)
                $null = Save-Report -ExitCode $script:EXIT_ABORTED -Result 'ABORTED'
                Show-Summary -Results $script:Deployment.Results -ExitCode $script:EXIT_ABORTED
                exit $script:EXIT_ABORTED
            }
        }
        $selIds = @($selectedTargets | ForEach-Object { $_.Id })
        foreach ($a in $actions) {
            if ($a.Id -notin $selIds) { $a.Status = 'SKIP' }
        }
        foreach ($a in $selectedTargets) {
            $startAt = Get-Date
            $a.Error = ''
            Write-Host ''
            Write-Host ('>>> [UNINSTALL] ' + $a.DisplayName + '  ' + $a.InstalledVersion)
            Write-Log ('Action started: ' + $a.Id + ' status=UNINSTALL')
            Stop-ProductServices $a.Services
            Stop-ProductProcesses $a.Processes
            $uninstallLog = Join-Path $script:Deployment.SessionDir ($a.Id + '-uninstall.log')
            Write-Log ('Uninstalling ' + $a.Id + ' (ProductCode ' + $a.Installed.ProductCode + ')')
            $ur = Uninstall-MsiProduct -ProductCode $a.Installed.ProductCode -UninstallLog $uninstallLog -ProductId $a.Id -TimeoutSeconds $uninstallTimeout
            $a.UninstallExitCode = $ur.ExitCode
            if ($ur.TimedOut) {
                Write-Host ('  Uninstall timed out') -ForegroundColor Red
                $a.Status = 'ERROR'
                $a.Error = 'Uninstall timed out'
                $script:Deployment.CountFailed++
                continue
            }
            if (-not $ur.Ok) {
                $msg = ConvertTo-MsiStatusText $ur.ExitCode
                Write-Host ('  Uninstall FAILED with exit code ' + $ur.ExitCode + ' (' + $msg + ')') -ForegroundColor Red
                $a.Status = 'ERROR'
                $a.Error = 'Uninstall failed: ' + $msg
                $script:Deployment.CountFailed++
                continue
            }
            $a.Status = 'UNINSTALLED'
            $script:Deployment.CountUninstalled++
            Write-Log ('Uninstall OK (exit ' + $ur.ExitCode + ')')
            Write-Host ('  [OK] ' + $a.DisplayName + ' uninstalled') -ForegroundColor Green
            $elapsed = ((Get-Date) - $startAt).TotalSeconds
            Write-Log ('Action completed: ' + $a.Id + ' elapsed=' + [math]::Round($elapsed, 1) + 's')
        }
        $hasFailed = $script:Deployment.CountFailed -gt 0
        if ($hasFailed) { $resultName = 'COMPLETED_WITH_ERRORS'; $exit = $script:EXIT_ERRORS }
        else { $resultName = 'SUCCESS'; $exit = $script:EXIT_OK }
        if (-not $hasFailed -and $cleanupOnSuccess) {
            try { Remove-Item -Path $tempSession -Recurse -Force -ErrorAction SilentlyContinue; Write-Log ('Temporary files removed: ' + $tempSession) } catch { }
        } elseif ($keepTemp) { Write-Log ('Temporary files kept (KeepTemp): ' + $tempSession) }
        $script:Deployment.Results = @(New-ReportResults -Actions $actions)
        $null = Save-Report -ExitCode $exit -Result $resultName
        Show-Summary -Results $script:Deployment.Results -ExitCode $exit
        Write-Host ('Report: ' + $script:Deployment.ReportFile)
        exit $exit
    }

    if ($mode -eq 'UPDATE') {
        foreach ($a in @($actions | Where-Object { $_.Status -eq 'MISSING' })) {
            $a.Status = 'SKIP'
            $a.Error = 'Not installed; update-only mode'
            Write-Log ($a.Id + ': not installed, skipped (update-only mode)')
        }
        $offer = @($actions | Where-Object { $_.Status -eq 'UPDATE' } | Sort-Object Order, Id)
    } else {
        $missing = @($actions | Where-Object { $_.Status -eq 'MISSING' })
        if ($script:Deployment.AutoApprove -or $script:Deployment.NonInteractive) {
            foreach ($a in $missing) {
                $a.Status = 'INSTALL'
                Write-Log ($a.Id + ': auto-selected for install (AutoApprove/NonInteractive)')
            }
        }
        $offer = @($actions | Where-Object { $_.Status -in @('UPDATE', 'INSTALL') } | Sort-Object Order, Id)
    }

    if ($offer.Count -gt 0 -and -not ($script:Deployment.AutoApprove -or $script:Deployment.NonInteractive)) {
        $modeLabel = if ($mode -eq 'UPDATE') { 'Components to update' } else { 'Components to install/update' }
        $selected = @(Ask-NumberedSelection -Items $offer -Title $modeLabel)
        $selIds = @($selected | ForEach-Object { $_.Id })
        foreach ($a in $offer) {
            if ($a.Id -notin $selIds) {
                $a.Status = 'SKIP'
                $a.Error = 'Not selected'
                Write-Log ($a.Id + ': not selected, skipped')
            } elseif ($mode -eq 'INSTALL' -and $a.Status -eq 'MISSING') {
                $a.Status = 'INSTALL'
                Write-Log ($a.Id + ': selected for install')
            }
        }
        if ($selected.Count -eq 0) {
            Write-Log 'No components selected'
            foreach ($a in $actions) { $a.Status = 'ABORTED'; $a.Error = 'No components selected' }
            $null = Save-Report -ExitCode $script:EXIT_ABORTED -Result 'ABORTED'
            Show-Summary -Results $actions -ExitCode $script:EXIT_ABORTED
            exit $script:EXIT_ABORTED
        }
    }

    $doActions = @($actions | Where-Object { $_.Status -in @('UPDATE', 'INSTALL') } | Sort-Object Order, Id)

    $hasChanges = $doActions.Count -gt 0
    $confirmResult = $true
    if ($hasChanges -and -not ($script:Deployment.AutoApprove -or $script:Deployment.NonInteractive)) {
        Write-Host '================================'
        $confirmResult = Ask-YesNo -Prompt 'Continue'
        Write-Host ''
    }
    if (-not $confirmResult) {
        Write-Log 'Deployment aborted by user'
        $forReport = @($actions | ForEach-Object { $_.Status = 'ABORTED'; $_ })
        $null = Save-Report -ExitCode $script:EXIT_ABORTED -Result 'ABORTED'
        Show-Summary -Results $forReport -ExitCode $script:EXIT_ABORTED
        exit $script:EXIT_ABORTED
    }

    foreach ($a in $doActions) {
        $startAt = Get-Date
        $a.Error = ''
        Write-Host ''
        if ($a.Status -eq 'UPDATE') {
            Write-Host ('>>> [UPDATE] ' + $a.DisplayName + '  ' + $a.OldVersion + ' -> ' + $a.NewVersion)
        } else {
            Write-Host ('>>> [INSTALL] ' + $a.DisplayName + '  ' + $a.NewVersion)
        }
        Write-Log ('Action started: ' + $a.Id + ' status=' + $a.Status)

        Stop-ProductServices $a.Services
        Stop-ProductProcesses $a.Processes

        if ($a.Status -eq 'UPDATE' -and $null -ne $a.Installed -and $a.Installed.ProductCode) {
            $uninstallLog = Join-Path $script:Deployment.SessionDir ($a.Id + '-uninstall.log')
            Write-Log ('Uninstalling ' + $a.Id + ' (ProductCode ' + $a.Installed.ProductCode + ')')
            $ur = Uninstall-MsiProduct -ProductCode $a.Installed.ProductCode -UninstallLog $uninstallLog -ProductId $a.Id -TimeoutSeconds $uninstallTimeout
            $a.UninstallExitCode = $ur.ExitCode
            if ($ur.TimedOut) {
                Write-Host ('  Uninstall timed out, aborting ' + $a.Id) -ForegroundColor Red
                $a.Status = 'ERROR'
                $a.Error = 'Uninstall timed out'
                $script:Deployment.CountFailed++
                continue
            }
            if (-not $ur.Ok) {
                $msg = ConvertTo-MsiStatusText $ur.ExitCode
                Write-Host ('  Uninstall FAILED with exit code ' + $ur.ExitCode + ' (' + $msg + '), skipping install') -ForegroundColor Red
                $a.Status = 'ERROR'
                $a.Error = 'Uninstall failed: ' + $msg
                $script:Deployment.CountFailed++
                continue
            }
            Write-Log ('Uninstall OK (exit ' + $ur.ExitCode + ')')
        }

        if ($a.Candidate) {
            $destMsi = Join-Path $script:Deployment.MsiTempDir $a.Candidate.Name
            try {
                Expand-ZipEntry -ZipPath $archivePath -EntryName $a.Candidate.FullName -DestinationPath $destMsi
                $a.MsiPath = $destMsi
            } catch {
                Write-Host ('  Failed to re-extract MSI for ' + $a.DisplayName + ': ' + $_.Exception.Message) -ForegroundColor Red
                $a.Status = 'ERROR'
                $a.Error = 'Failed to re-extract MSI: ' + $_.Exception.Message
                $script:Deployment.CountFailed++
                continue
            }
        }

        $installLog = Join-Path $script:Deployment.SessionDir ($a.Id + '-install.log')
        Write-Log ('Installing ' + $a.Id + ' from ' + $a.MsiPath)
        $ir = Install-MsiPackage -MsiPath $a.MsiPath -InstallLog $installLog -ProductId $a.Id -TimeoutSeconds $installTimeout
        $a.InstallExitCode = $ir.ExitCode
        if ($ir.TimedOut) {
            Write-Host ('  Install timed out') -ForegroundColor Red
            $a.Status = 'ERROR'
            $a.Error = 'Install timed out'
            $script:Deployment.CountFailed++
            continue
        }
        if (-not $ir.Ok) {
            $msg = ConvertTo-MsiStatusText $ir.ExitCode
            Write-Host ('  Install FAILED with exit code ' + $ir.ExitCode + ' (' + $msg + ')') -ForegroundColor Red
            $a.Status = 'ERROR'
            $a.Error = 'Install failed: ' + $msg
            $script:Deployment.CountFailed++
            continue
        }
        Write-Log ('Install returned exit ' + $ir.ExitCode)

        $fresh = Get-SePlatformInventory
        $vres = Verify-MsiInstallation -ProductId $a.Id -ExpectedVersion $a.NewVersion -Inventory $fresh
        $a.Verified = $vres.Ok
        if ($vres.Ok) {
            $a.Status = 'OK'
            $script:Deployment.CountUpdated++
            Write-Host ('  [OK] ' + $vres.DisplayName + ' ' + $vres.DisplayVersion) -ForegroundColor Green
        } else {
            $a.Status = 'ERROR'
            $a.Error = 'Verification failed: ' + $vres.Error
            $a.InstalledVersion = $vres.DisplayVersion
            $script:Deployment.CountFailed++
            Write-Host ('  [ERROR] Verification failed: ' + $vres.Error) -ForegroundColor Red
        }

        if ($vres.Ok -and $a.Services.Count -gt 0) {
            foreach ($svc in $a.Services) {
                try {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($null -ne $s -and $s.Status -eq 'Stopped') {
                        Start-Service -Name $svc -ErrorAction SilentlyContinue
                        Write-Log ('Service started after install: ' + $svc)
                    }
                } catch { }
            }
        }
        $elapsed = ((Get-Date) - $startAt).TotalSeconds
        Write-Log ('Action completed: ' + $a.Id + ' elapsed=' + [math]::Round($elapsed, 1) + 's')
    }

    foreach ($r in $actions) {
        switch ($r.Status) {
            'OK'       { $script:Deployment.CountOk++ }
            'UPDATE'   { $script:Deployment.CountOk++ }
            'INSTALL'  { continue }
            'SKIP'     { $script:Deployment.CountSkipped++ }
            'SKIP_NEWER' { $script:Deployment.CountSkipped++ }
            'NO_MSI'   { $script:Deployment.CountSkipped++ }
            'BLOCKED'  { $script:Deployment.CountFailed++ }
            default    { $script:Deployment.CountSkipped++ }
        }
    }

    $script:Deployment.Results = @(New-ReportResults -Actions $actions)

    $hasFailed = $script:Deployment.CountFailed -gt 0
    if ($hasFailed) {
        $resultName = 'COMPLETED_WITH_ERRORS'
        $exit = $script:EXIT_ERRORS
    } else {
        $resultName = 'SUCCESS'
        $exit = $script:EXIT_OK
    }

    $saveTemp = ($keepTemp) -or ($hasFailed -and $keepTemp)
    if (-not $hasFailed -and $cleanupOnSuccess) {
        try {
            Remove-Item -Path $tempSession -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log ('Temporary files removed: ' + $tempSession)
        } catch { }
    } elseif ($keepTemp) {
        Write-Log ('Temporary files kept (KeepTemp): ' + $tempSession)
    }

    $null = Save-Report -ExitCode $exit -Result $resultName
    Show-Summary -Results $actions -ExitCode $exit
    Write-Host ('Report: ' + $script:Deployment.ReportFile)
    exit $exit

} catch {
    $errMsg = $_.Exception.Message
    if ($script:Deployment.LogFile) {
        Add-Content -Path $script:Deployment.LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [FATAL] ' + $errMsg) -Encoding UTF8
    }
    Write-Host ''
    Write-Host ('FATAL ERROR: ' + $errMsg) -ForegroundColor Red
    Write-Host ''
    Write-Host ('Logs: ' + $script:Deployment.SessionDir)
    Write-Host ''
    exit $script:EXIT_BAD_PARAMS
}