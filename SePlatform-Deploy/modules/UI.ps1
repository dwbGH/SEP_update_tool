function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title
    Write-Host ('=' * $Title.Length)
    Write-Host ''
}

function Ask-StartupMode {
    param([string]$DefaultArchive = '')
    Write-Host ''
    Write-Host 'SePlatform Deploy Tool'
    Write-Host '======================'
    Write-Host ''
    Write-Host 'What do you want to do?'
    Write-Host ''
    Write-Host '  [1] Install/update components from ZIP archive (MSI)'
    Write-Host '  [2] Manage additional SePlatform.Data Server copies (services)'
    Write-Host '  [3] Exit'
    Write-Host ''
    while ($true) {
        Write-Host -NoNewline 'Select (1, 2 or 3): '
        $input = (Read-Host).Trim()
        switch ($input) {
            '1' {
                $archive = $null
                while ($true) {
                    if ($DefaultArchive) {
                        Write-Host -NoNewline ('Path to ZIP archive [default: ' + $DefaultArchive + ']: ')
                        $input = (Read-Host).Trim()
                        if ($input) { $archive = $input } else { $archive = $DefaultArchive }
                    } else {
                        Write-Host -NoNewline 'Path to ZIP archive: '
                        $input = (Read-Host).Trim()
                        $archive = $input
                    }
                    if ([string]::IsNullOrWhiteSpace($archive)) {
                        Write-Host 'Archive path cannot be empty.' -ForegroundColor Yellow
                        continue
                    }
                    if (Test-Path $archive) { break }
                    Write-Host ('Archive not found: ' + $archive) -ForegroundColor Yellow
                }
                return [pscustomobject]@{ Mode = 'COMPONENTS'; Archive = $archive }
            }
            '2' { return [pscustomobject]@{ Mode = 'SERVER_COPIES'; Archive = '' } }
            '3' { return [pscustomobject]@{ Mode = 'EXIT'; Archive = '' } }
            default { Write-Host 'Please enter 1, 2 or 3.' -ForegroundColor Yellow }
        }
    }
}

function Show-Plan {
    param([object[]]$Actions)
    Write-Host 'Archive: ' $script:Deployment.ArchivePath
    Write-Host 'Archive display: ' $script:Deployment.ArchiveName
    Write-Host 'OS: ' (Get-MachineFriendlyOs)
    if ($script:Deployment.WhatIf) { Write-Host 'Mode: DRY RUN (WhatIf) - no changes will be made'; Write-Host '' }
    else { Write-Host 'Mode: DEPLOY'; Write-Host '' }
    Write-Host 'Changes:'
    Write-Host ''

    $updates   = @($Actions | Where-Object { $_.Status -eq 'UPDATE' } | Sort-Object Order)
    $install   = @($Actions | Where-Object { $_.Status -eq 'INSTALL' } | Sort-Object Order)
    $ok        = @($Actions | Where-Object { $_.Status -eq 'OK' } | Sort-Object Order)
    $newer     = @($Actions | Where-Object { $_.Status -eq 'SKIP_NEWER' } | Sort-Object Order)
    $noMsi     = @($Actions | Where-Object { $_.Status -eq 'NO_MSI' } | Sort-Object Order)
    $blocked   = @($Actions | Where-Object { $_.Status -eq 'BLOCKED' } | Sort-Object Order)
    $missing   = @($Actions | Where-Object { $_.Status -eq 'MISSING' } | Sort-Object Order)

    if ($updates.Count -eq 0 -and $install.Count -eq 0 -and $ok.Count -eq 0 -and $newer.Count -eq 0 -and $noMsi.Count -eq 0 -and $blocked.Count -eq 0) {
        Write-Host 'Nothing to do.'
        Write-Host ''
    }

    foreach ($a in $updates) {
        Write-Host ('[UPDATE] ' + $a.DisplayName)
        Write-Host ('        ' + $a.OldVersion + ' -> ' + $a.NewVersion)
        Write-Host ''
    }
    foreach ($a in $install) {
        Write-Host ('[INSTALL] ' + $a.DisplayName)
        Write-Host ('        ' + $a.NewVersion)
        if ($a.DependencyIssues) {
            foreach ($d in $a.DependencyIssues) { Write-Host ('        [DEPENDENCY] ' + $d) -ForegroundColor Yellow }
        }
        Write-Host ''
    }
    foreach ($a in $ok) {
        Write-Host ('[OK] ' + $a.DisplayName)
        Write-Host ('        ' + $a.InstalledVersion)
        Write-Host ''
    }
    foreach ($a in $newer) {
        Write-Host ('[SKIP] ' + $a.DisplayName)
        Write-Host ('        installed version is newer than the archive')
        Write-Host ''
    }
    foreach ($a in $noMsi) {
        Write-Host ('[SKIP] ' + $a.DisplayName)
        Write-Host ('        no matching MSI found in the archive for this platform')
        Write-Host ''
    }
    foreach ($a in $blocked) {
        Write-Host ('[ERROR] ' + $a.DisplayName)
        Write-Host ('        prerequisites not satisfied (see Dependencies)')
        Write-Host ''
    }

    if ($missing.Count -gt 0) {
        Write-Host ('Missing (not installed):')
        Write-Host ''
        $i = 1
        foreach ($a in $missing) {
            Write-Host ('[{0}] {1}  {2}' -f $i, $a.DisplayName, $a.NewVersion)
            $i++
        }
        Write-Host ''
    }

    $allDeps = @($Actions | ForEach-Object {
        foreach ($d in $_.Dependencies) {
            [pscustomobject]@{ ProductId = $_.Id; Kind = $d.kind; Description = $d.description; Found = $d.found; Min = $d.minVersion; Ok = $d.ok; Blocking = $d.blocking }
        }
    })
    if ($allDeps.Count -gt 0) {
        Write-Host 'Dependencies:'
        Write-Host ''
        foreach ($d in $allDeps) {
            $status = if ($d.Ok) { '[OK]' } else { '[ERROR]' }
            $line = ($status + ' ' + $d.Description + ' (found: ' + $d.Found + ')')
            Write-Host $line
        }
        Write-Host ''
    }

    try {
        $serverInstances = Get-SePlatformServerInstances
        if ($serverInstances.Count -gt 0) {
            Show-ServerInstancesTable $serverInstances
        }
    } catch {
        Write-Log ('Server copies detection failed: ' + $_.Exception.Message) -Level 'WARN'
    }
}

function Ask-DeployMode {
    Write-Host ''
    Write-Host 'Deployment mode:'
    Write-Host ''
    Write-Host '  [1] Update existing components (do not install missing)'
    Write-Host '  [2] Install and update (including missing components)'
    Write-Host '  [3] Uninstall components'
    Write-Host '  [4] Exit'
    Write-Host ''
    while ($true) {
        Write-Host -NoNewline 'Select mode: '
        $input = (Read-Host).Trim()
        switch ($input) {
            '1' { return 'UPDATE' }
            '2' { return 'INSTALL' }
            '3' { return 'UNINSTALL' }
            '4' { return 'EXIT' }
            default { Write-Host 'Please enter 1, 2, 3 or 4.' -ForegroundColor Yellow }
        }
    }
}

function Ask-NumberedSelection {
    param(
        [object[]]$Items,
        [string]$Title = 'items'
    )
    if ($Items.Count -eq 0) { return @() }
    Write-Host ''
    Write-Host ($Title + ':')
    Write-Host ''
    $i = 1
    foreach ($it in $Items) {
        $ver = if ($it.InstalledVersion) { $it.InstalledVersion } elseif ($it.NewVersion) { $it.NewVersion } else { '' }
        $label = $it.DisplayName
        if ($ver) { $label += '  ' + $ver }
        if ($it.Status -eq 'MISSING') { $label += '  [not installed]' }
        Write-Host ('[{0}] {1}' -f $i, $label)
        $i++
    }
    Write-Host ''
    while ($true) {
        Write-Host -NoNewline ('Select (1-' + $Items.Count + '), e.g. 1-5,10-20 / A / N: ')
        $input = Read-Host
        $input = $input.Trim()
        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Host 'Invalid input. Please try again.' -ForegroundColor Yellow
            continue
        }
        if ($input -match '^[Nn]$') { return @() }
        if ($input -match '^[Aa]$') { return @($Items) }
        $tokens = [regex]::Split($input, '[\s,;]+') | Where-Object { $_ -ne '' }
        $selected = New-Object System.Collections.Generic.List[object]
        $valid = $true
        foreach ($t in $tokens) {
            $range = [regex]::Match($t, '^(\d+)\s*-\s*(\d+)$')
            if ($range.Success) {
                $from = [int]$range.Groups[1].Value
                $to = [int]$range.Groups[2].Value
                if ($from -lt 1 -or $from -gt $to -or $to -gt $Items.Count) { $valid = $false; break }
                for ($idx = $from; $idx -le $to; $idx++) {
                    if (-not $selected.Contains($Items[$idx - 1])) { $selected.Add($Items[$idx - 1]) }
                }
            } elseif ($t -match '^\d+$') {
                $idx = [int]$t
                if ($idx -lt 1 -or $idx -gt $Items.Count) { $valid = $false; break }
                if (-not $selected.Contains($Items[$idx - 1])) { $selected.Add($Items[$idx - 1]) }
            } else {
                $valid = $false
                break
            }
        }
        if (-not $valid) {
            Write-Host 'Invalid input. Please enter numbers or ranges like 1-5,10-20, A or N.' -ForegroundColor Yellow
            continue
        }
        return ($selected.ToArray())
    }
}

function New-ReportResults {
    param([object[]]$Actions)
    $results = @()
    foreach ($a in $Actions) {
        $results += [ordered]@{
            id             = $a.Id
            displayName    = $a.DisplayName
            group          = $a.Group
            required       = $a.Required
            status         = $a.Status
            oldVersion     = $a.OldVersion
            newVersion     = $a.NewVersion
            msiFile        = if ($a.Candidate) { $a.Candidate.Name } else { '' }
            installExitCode = $a.InstallExitCode
            uninstallExitCode = $a.UninstallExitCode
            verified       = $a.Verified
            error          = $a.Error
        }
    }
    return $results
}

function Ask-YesNo {
    param([string]$Prompt = 'Continue?')
    while ($true) {
        Write-Host -NoNewline ($Prompt + ' [Y/N]: ')
        $input = Read-Host
        $input = $input.Trim()
        if ($input -match '^[Yy](es)?$') { return $true }
        if ($input -match '^[Nn]o?$') { return $false }
        Write-Host 'Please answer Y or N.' -ForegroundColor Yellow
    }
}

function Show-Summary {
    param([object[]]$Results, [int]$ExitCode)
    Write-Host ''
    Write-Host '========================================'
    Write-Host 'DEPLOYMENT SUMMARY'
    Write-Host '========================================'
    Write-Host ''
    Write-Host ('Updated:   {0}' -f $script:Deployment.CountUpdated)
    Write-Host ('Installed: {0}' -f $script:Deployment.CountInstalled)
    Write-Host ('Uninstalled: {0}' -f $script:Deployment.CountUninstalled)
    Write-Host ('Confirmed: {0}' -f $script:Deployment.CountOk)
    Write-Host ('Skipped:   {0}' -f $script:Deployment.CountSkipped)
    Write-Host ('Failed:    {0}' -f $script:Deployment.CountFailed)
    Write-Host ''
    foreach ($r in $Results) {
        $marker = '???'
        switch ($r.Status) {
            'OK'         { $marker = '[OK]' }
            'UPDATE'     { $marker = '[OK]' }
            'INSTALL'    { $marker = '[OK]' }
            'UNINSTALLED' { $marker = '[OK]' }
            'SKIP'       { $marker = '[SKIP]' }
            'SKIP_UP_TO_DATE' { $marker = '[SKIP]' }
            'ERROR'    { $marker = '[ERROR]' }
            'NO_MSI'   { $marker = '[SKIP]' }
            'BLOCKED'  { $marker = '[ERROR]' }
            'ABORTED'  { $marker = '[ABORTED]' }
            default    { $marker = '[INFO]' }
        }
        $line = ($marker + ' ' + $r.DisplayName)
        if ($r.Error) { $line += (' - ' + $r.Error) }
        Write-Host $line
    }
    Write-Host ''
    Write-Host ('Logs: ' + $script:Deployment.SessionDir)
    Write-Host ('Exit code: ' + $ExitCode)
    Write-Host ''
}