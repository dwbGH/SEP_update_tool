function Install-MsiPackage {
    param(
        [string]$MsiPath,
        [string]$InstallLog,
        [string]$ProductId,
        [int]$TimeoutSeconds = 900
    )
    $result = Invoke-MsiExec -Operation 'i' -Target $MsiPath -LogPath $InstallLog -TimeoutSeconds $TimeoutSeconds
    $ok = ($result.ExitCode -eq 0) -or ($result.ExitCode -eq 3010)
    return [pscustomobject]@{
        ProductId  = $ProductId
        ExitCode   = $result.ExitCode
        TimedOut   = $result.TimedOut
        Error      = $result.Error
        Ok         = $ok
    }
}

function ConvertTo-MsiStatusText {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0    { 'Success' }
        3010 { 'Success, restart required' }
        1601 { 'Cannot access Windows Installer service' }
        1602 { 'User cancelled installation' }
        1603 { 'Fatal error during installation' }
        1618 { 'Another installation is already in progress' }
        1620 { 'Installation package was not openable' }
        1621 { 'Command line options invalid' }
        1622 { 'Unsupported product type' }
        1623 { 'Invalid feature' }
        1624 { 'Invalid feature state' }
        1625 { 'Invalid product state' }
        1631 { 'Service install failed' }
        1633 { 'Installation package already in progress' }
        1639 { 'Invalid command line' }
        1641 { 'Restart initiated' }
        1716 { 'Uninstall not possible' }
        9998 { 'Failed to start msiexec.exe' }
        9999 { 'msiexec timed out' }
        default { ('Exit code ' + $ExitCode) }
    }
}