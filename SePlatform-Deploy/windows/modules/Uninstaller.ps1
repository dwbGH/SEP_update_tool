function Stop-ProductServices {
    param([object[]]$Services)
    foreach ($svc in $Services) {
        $name = [string]$svc
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        try {
            $s = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $s -and $s.Status -ne 'Stopped') {
                Write-Log ('Stopping service: ' + $name)
                Stop-Service -Name $name -Force -ErrorAction Stop
                for ($i = 0; $i -lt 15; $i++) {
                    Start-Sleep -Milliseconds 500
                    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
                    if ($null -eq $s -or $s.Status -eq 'Stopped') { break }
                }
            }
        } catch {
            Write-Log ('Unable to stop service ' + $name + ': ' + $_.Exception.Message) -Level 'WARN'
        }
    }
}

function Stop-ProductProcesses {
    param([object[]]$Processes)
    foreach ($proc in $Processes) {
        $name = [string]$proc
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        try {
            $p = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $p) {
                Write-Log ('Stopping process: ' + $name)
                $p | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log ('Unable to stop process ' + $name + ': ' + $_.Exception.Message) -Level 'WARN'
        }
    }
}

function Uninstall-MsiProduct {
    param(
        [string]$ProductCode,
        [string]$UninstallLog,
        [string]$ProductId,
        [int]$TimeoutSeconds = 600
    )
    if ([string]::IsNullOrWhiteSpace($ProductCode)) {
        return [pscustomobject]@{ ProductId = $ProductId; ExitCode = -1; TimedOut = $false; Error = 'No ProductCode'; Ok = $false }
    }
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}\}$') {
        return [pscustomobject]@{ ProductId = $ProductId; ExitCode = -1; TimedOut = $false; Error = 'Invalid ProductCode format: ' + $ProductCode; Ok = $false }
    }
    $result = Invoke-MsiExec -Operation 'x' -Target $ProductCode -LogPath $UninstallLog -TimeoutSeconds $TimeoutSeconds
    $ok = ($result.ExitCode -eq 0) -or ($result.ExitCode -eq 3010)
    return [pscustomobject]@{
        ProductId = $ProductId
        ExitCode  = $result.ExitCode
        TimedOut  = $result.TimedOut
        Error     = $result.Error
        Ok        = $ok
    }
}