function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = ($stamp + ' [' + $Level + '] ' + $Message)
    if (-not $NoConsole) {
        switch ($Level) {
            'ERROR'  { Write-Host $line -ForegroundColor Red }
            'WARN'   { Write-Host $line -ForegroundColor Yellow }
            'OK'     { Write-Host $line -ForegroundColor Green }
            default  { Write-Host $line }
        }
    }
    if ($script:Deployment.LogFile) {
        try {
            Add-Content -Path $script:Deployment.LogFile -Value $line -Encoding UTF8
        } catch { }
    }
}

function New-LogSession {
    param(
        [string]$BaseRoot,
        [string]$ArchiveName,
        [switch]$WhatIf,
        [switch]$NonInteractive
    )
    $sessionName = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $sessionDir = Join-Path $BaseRoot $sessionName
    if (-not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }
    $script:Deployment.SessionDir = $sessionDir
    $script:Deployment.LogFile = Join-Path $sessionDir 'Deployment.log'
    Add-Content -Path $script:Deployment.LogFile -Value ('SePlatform Deployment Tool session started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
    Add-Content -Path $script:Deployment.LogFile -Value ('Archive: ' + $ArchiveName) -Encoding UTF8
    Add-Content -Path $script:Deployment.LogFile -Value ('WhatIf: ' + [bool]$WhatIf) -Encoding UTF8
    Add-Content -Path $script:Deployment.LogFile -Value ('NonInteractive: ' + [bool]$NonInteractive) -Encoding UTF8
    Add-Content -Path $script:Deployment.LogFile -Value ('Host: ' + $env:COMPUTERNAME) -Encoding UTF8
    Add-Content -Path $script:Deployment.LogFile -Value '' -Encoding UTF8
    return $sessionDir
}

function Save-Report {
    param([int]$ExitCode, [string]$Result)
    $report = [ordered]@{
        toolVersion = '1.0'
        timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        archive     = $script:Deployment.ArchivePath
        machine     = $env:COMPUTERNAME
        os          = Get-MachineFriendlyOs
        result      = $Result
        exitCode    = $ExitCode
        counters    = [ordered]@{
            updated   = $script:Deployment.CountUpdated
            installed = $script:Deployment.CountInstalled
            uninstalled = $script:Deployment.CountUninstalled
            skipped   = $script:Deployment.CountSkipped
            ok        = $script:Deployment.CountOk
            failed    = $script:Deployment.CountFailed
        }
        products    = @($script:Deployment.Results)
    }
    $null = Add-ServerCopiesToReport -Report $report
    $json = $report | ConvertTo-Json -Depth 6
    $reportFile = Join-Path $script:Deployment.SessionDir 'report.json'
    $json | Out-File -FilePath $reportFile -Encoding UTF8
    $script:Deployment.ReportFile = $reportFile
    return $reportFile
}

function Add-ServerCopiesToReport {
    param($Report)
    $inventory = @()
    $actions = @()
    try {
        if (Get-Command Get-SePlatformServerInstances -ErrorAction SilentlyContinue) {
            $detected = Get-SePlatformServerInstances
            $inventory = @($detected | ForEach-Object {
                [ordered]@{
                    folder      = $_.FolderPath
                    serviceName = $_.ServiceName
                    port        = $_.Port
                    instanceId  = $_.InstanceId
                    isMain      = $_.IsMain
                    state       = $_.ServiceState
                    hasInstaller = $_.HasInstaller
                }
            })
        }
    } catch {
        $inventory = @()
    }
    if ($null -ne $script:ServerCopiesState -and $script:ServerCopiesState.Results.Count -gt 0) {
        $actions = @($script:ServerCopiesState.Results | ForEach-Object {
            [ordered]@{
                action      = $_.Action
                status      = $_.Status
                folder      = if ($_.FolderName) { $_.FolderName } else { '' }
                serviceName = if ($_.ServiceName) { $_.ServiceName } else { '' }
                port        = if ($null -ne $_.Port) { $_.Port } else { '' }
                instanceId  = if ($_.InstanceId) { $_.InstanceId } else { '' }
                error       = if ($_.Error) { $_.Error } else { '' }
            }
        })
    }
    $Report['serverCopiesDetected'] = $inventory
    $Report['serverCopiesActions'] = $actions
    return $Report
}