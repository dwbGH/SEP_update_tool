$script:ServerCopiesState = @{
    Instances    = @()
    Results      = @()
}

function Get-ServerCopiesConfig {
    if ($null -ne $script:Deployment.Config -and $script:Deployment.Config.PSObject.Properties['serverCopies']) {
        return $script:Deployment.Config.serverCopies
    }
    return $null
}

function Get-ServerCopyRoot {
    $sc = Get-ServerCopiesConfig
    $root = 'C:\Program Files\SePlatform'
    if ($null -ne $sc -and $sc.PSObject.Properties['serverRoot'] -and $sc.serverRoot) {
        $root = [string]$sc.serverRoot
    }
    return ConvertTo-ResolvedPath $root
}

function Get-ServerCopyMainFolderName {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['mainFolder'] -and $sc.mainFolder) {
        return [string]$sc.mainFolder
    }
    return 'SePlatform.Server'
}

function Get-ServerCopyExeName {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['exeName'] -and $sc.exeName) {
        return [string]$sc.exeName
    }
    return 'SePlatform.Server.exe'
}

function Get-ServerCopyInstallerExeName {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['installerExeName'] -and $sc.installerExeName) {
        return [string]$sc.installerExeName
    }
    return 'SePlatform.ServerInstaller.exe'
}

function Get-ServerCopyConfigFileName {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['configFileName'] -and $sc.configFileName) {
        return [string]$sc.configFileName
    }
    return 'SePlatform.Server.xml'
}

function Get-ServerCopyJsonFileName {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['jsonConfigFileName'] -and $sc.jsonConfigFileName) {
        return [string]$sc.jsonConfigFileName
    }
    return 'SePlatform.Server.json'
}

function Get-ServerCopySubDir {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['serverSubDir'] -and $sc.serverSubDir) {
        return [string]$sc.serverSubDir
    }
    return 'Server'
}

function Get-ServerCopyTimeoutSeconds {
    if ($null -ne $script:Deployment.Config -and $script:Deployment.Config.PSObject.Properties['serverCopyTimeoutSeconds']) {
        return [int]$script:Deployment.Config.serverCopyTimeoutSeconds
    }
    return 900
}

function Get-ServerCopyDisableProgIdRewrite {
    $sc = Get-ServerCopiesConfig
    if ($null -ne $sc -and $sc.PSObject.Properties['disableProgIdRewrite']) {
        return ConvertTo-Boolean $sc.disableProgIdRewrite $false
    }
    return $false
}

function Test-ServerCopyPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $false }
    $sub = Get-ServerCopySubDir
    $exe = Join-Path $Path (Join-Path $sub (Get-ServerCopyExeName))
    $cfg = Join-Path $Path (Join-Path $sub (Get-ServerCopyConfigFileName))
    return ((Test-Path $exe) -and (Test-Path $cfg))
}

function Get-ServerInstanceFromFolder {
    param([string]$FolderPath)
    if (-not (Test-ServerCopyPath $FolderPath)) { return $null }
    $sub = Get-ServerCopySubDir
    $cfgFile = Join-Path $FolderPath (Join-Path $sub (Get-ServerCopyConfigFileName))
    $jsonFile = Join-Path $FolderPath (Join-Path $sub (Get-ServerCopyJsonFileName))
    $cfg = Read-ServerConfigDom $cfgFile
    $serviceName = [string]$cfg.ServiceName
    $port = [string]$cfg.Port
    $instanceId = Read-ServerInstanceIdFromJson $jsonFile
    if (-not $instanceId) { $instanceId = [string]$cfg.InstanceId }
    $backupPath = [string]$cfg.BackupPath
    $comServers = @()
    if ($null -ne $cfg.ComServers) {
        foreach ($c in $cfg.ComServers) {
            if ($null -ne $c -and $c.ProgID) {
                $comServers += [pscustomobject]@{
                    ProgID = [string]$c.ProgID
                    CLSID  = [string]$c.CLSID
                    Tag    = [string]$c.Tag
                }
            }
        }
    }
    $svc = $null
    if ($serviceName) { $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue }
    if ($null -ne $svc -and -not (Test-ServiceBelongsToFolder $serviceName $FolderPath)) {
        Write-Log ('Service ' + $serviceName + ' does not belong to folder ' + $FolderPath + '; not bound to this instance.') -Level 'WARN'
        $svc = $null
    }
    $installer = Join-Path $FolderPath (Join-Path $sub (Get-ServerCopyInstallerExeName))
    return [pscustomobject]@{
        FolderPath    = $FolderPath
        FolderName    = Split-Path -Leaf $FolderPath
        ConfigPath    = $cfgFile
        ServiceName   = $serviceName
        Port          = $port
        InstanceId    = $instanceId
        BackupPath    = $backupPath
        ComServers    = $comServers
        HasInstaller  = (Test-Path $installer)
        IsMain        = ((Split-Path -Leaf $FolderPath) -eq (Get-ServerCopyMainFolderName))
        ServiceState  = if ($null -ne $svc) { $svc.Status.ToString() } else { 'NotInstalled' }
        ServiceExists = ($null -ne $svc)
    }
}

function Get-ServiceImagePath {
    param([string]$ServiceName)
    if (-not $ServiceName) { return '' }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $ServiceName
    if (-not (Test-Path $key)) { return '' }
    try {
        $img = (Get-ItemProperty -Path $key -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        return [string]$img
    } catch { return '' }
}

function Test-ServiceBelongsToFolder {
    param([string]$ServiceName, [string]$FolderPath)
    $img = Get-ServiceImagePath $ServiceName
    if (-not $img) { return $false }
    $normImg = $img.Trim('"').Replace('/','\').ToLowerInvariant()
    $normFolder = $FolderPath.TrimEnd('\').ToLowerInvariant()
    return $normImg.StartsWith($normFolder + '\')
}

function Read-ServerConfigDom {
    param([string]$ConfigPath)
    $result = [pscustomobject]@{
        ServiceName = ''
        Port        = ''
        InstanceId  = ''
        BackupPath  = ''
        ComServers  = @()
    }
    if (-not (Test-Path $ConfigPath)) { return $result }
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($ConfigPath)
        $install = $xml.DocumentElement.SelectSingleNode('//*[local-name()="install"]')
        if ($null -ne $install) { $result.ServiceName = [string]$install.GetAttribute('ServiceName') }
        $conn = $xml.DocumentElement.SelectSingleNode('//*[local-name()="Connection"]')
        if ($null -ne $conn) { $result.Port = [string]$conn.GetAttribute('Port') }
        $inst = $xml.DocumentElement.SelectSingleNode('//*[local-name()="Instance"]')
        if ($null -ne $inst) { $result.InstanceId = [string]$inst.GetAttribute('ID') }
        $bkp = $xml.DocumentElement.SelectSingleNode('//*[local-name()="Backup"]')
        if ($null -ne $bkp) { $result.BackupPath = [string]$bkp.GetAttribute('Path') }
        foreach ($n in $xml.DocumentElement.SelectNodes('//*[@ProgID or @CLSID]')) {
            $progId = [string]$n.GetAttribute('ProgID')
            $clsId = [string]$n.GetAttribute('CLSID')
            if (-not $progId) { continue }
            $result.ComServers += [pscustomobject]@{
                Tag    = $n.Name
                ProgID = $progId
                CLSID  = $clsId
            }
        }
    } catch {
        Write-Log ('Server config parse failed: ' + $ConfigPath + ' - ' + $_.Exception.Message) -Level 'WARN'
    }
    return $result
}

function Get-SePlatformServerBackupFolder {
    param([string]$FolderPath)
    $subDir = Get-ServerCopySubDir
    $cfg = Read-ServerConfigDom (Join-Path $FolderPath (Join-Path $subDir (Get-ServerCopyConfigFileName)))
    $p = ''
    if (-not [string]::IsNullOrWhiteSpace($cfg.BackupPath)) {
        if ([System.IO.Path]::IsPathRooted($cfg.BackupPath)) {
            $p = $cfg.BackupPath
        } else {
            $p = [System.IO.Path]::GetFullPath((Join-Path $FolderPath (Join-Path $subDir $cfg.BackupPath)))
        }
        if (-not (Test-Path $p)) { $p = '' }
    }
    if (-not $p) {
        $fallback = Join-Path $FolderPath 'Backups'
        if (Test-Path $fallback) { $p = $fallback }
    }
    return $p
}

function Test-AdditionalServerPortFree {
    param([int]$Port)
    $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort
    return ($Port -notin $ports)
}

function Test-AdditionalServerInstanceIdFree {
    param([string]$InstanceId)
    $instances = Get-SePlatformServerInstances
    foreach ($i in $instances) {
        if ($i.InstanceId -and $i.InstanceId -eq $InstanceId) { return $false }
    }
    return $true
}

function Get-SePlatformServerInstances {
    if ($script:ServerCopiesState.Instances.Count -gt 0) { return $script:ServerCopiesState.Instances }
    $root = Get-ServerCopyRoot
    $mainName = Get-ServerCopyMainFolderName
    $result = @()
    if (-not (Test-Path $root)) {
        Write-Log ('Server root not found: ' + $root) -Level 'WARN'
        return ,$result
    }
    $folders = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like ($mainName + '*')
    }
    $known = @{}
    foreach ($f in $folders) {
        $inst = Get-ServerInstanceFromFolder $f.FullName
        if ($null -ne $inst) {
            $key = $inst.FolderPath.ToLowerInvariant()
            if (-not $known.ContainsKey($key)) {
                $known[$key] = $true
                $result += $inst
            }
        }
    }
    $result = @(
        $result | Sort-Object @{ Expression = { $_.IsMain }; Descending = $true }, FolderName
    )
    $script:ServerCopiesState.Instances = $result
    return ,$result
}

function Get-ServerCopyByIndex {
    param([int]$Index)
    $instances = Get-SePlatformServerInstances
    if ($Index -lt 1 -or $Index -gt $instances.Count) { return $null }
    return $instances[$Index - 1]
}

function Read-ServerConfigFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw 'Config file not found: ' + $Path }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = if ($hasBom) { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::GetEncoding(1251) }
    $offset = if ($hasBom) { 3 } else { 0 }
    return $enc.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Write-ServerConfigFile {
    param([string]$Path, [string]$Content)
    $enc = [System.Text.Encoding]::GetEncoding(1251)
    if (Test-Path $Path) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) { $enc = New-Object System.Text.UTF8Encoding($true) }
    }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Read-ServerInstanceIdFromJson {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return '' }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return '' }
        if ($null -eq $obj.PSObject.Properties['Instance'] -or $null -eq $obj.Instance) { return '' }
        if ($null -eq $obj.Instance.PSObject.Properties['Id']) { return '' }
        return ([string]$obj.Instance.Id).Trim()
    } catch {
        Write-Log ('Server instance JSON read failed: ' + $Path + ' - ' + $_.Exception.Message) -Level 'WARN'
        return ''
    }
}

function Write-ServerInstanceIdToJson {
    param([string]$Path, [string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { throw 'Instance ID is empty' }
    $obj = $null
    if (Test-Path $Path) {
        try {
            $raw = [System.IO.File]::ReadAllText($Path)
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $obj = $raw | ConvertFrom-Json }
        } catch {
            Write-Log ('Server instance JSON parse failed (rewriting): ' + $Path + ' - ' + $_.Exception.Message) -Level 'WARN'
            $obj = $null
        }
    }
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) {
        $obj = [pscustomobject]@{ Version = 0 }
    }
    if ($obj.PSObject.Properties['Instance'] -and $obj.Instance -is [System.Management.Automation.PSCustomObject]) {
        if ($obj.Instance.PSObject.Properties['Id']) {
            $obj.Instance.Id = $InstanceId
        } else {
            $obj.Instance | Add-Member -NotePropertyName Id -NotePropertyValue $InstanceId
        }
    } else {
        $obj | Add-Member -NotePropertyName Instance -NotePropertyValue ([pscustomobject]@{ Id = $InstanceId }) -Force
    }
    $json = $obj | ConvertTo-Json -Depth 10
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Find-ServerConfigInstanceIdElement {
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $null }
    $m = [regex]::Match($Content, '(?s)<Instance\b[^>]*?\bID="[^"]*"[^>]*?/>')
    if (-not $m.Success) {
        $m = [regex]::Match($Content, '(?s)<Instance\b[^>]*?\bID="[^"]*"[^>]*>.*?</Instance>')
    }
    if (-not $m.Success) { return $null }
    $before = $Content.Substring(0, $m.Index)
    $lastOpen = $before.LastIndexOf('<!--')
    $lastClose = $before.LastIndexOf('-->')
    if ($lastOpen -ge 0 -and $lastOpen -gt $lastClose) { return $null }
    return $m
}

function Set-ServerConfigInstanceId {
    param([string]$Content, [string]$Value)
    $m = Find-ServerConfigInstanceIdElement $Content
    if ($null -eq $m) { return $null }
    $tag = [regex]::Replace($m.Value, '(\bID=")[^"]*(")', ('${1}' + $Value + '${2}'))
    return $Content.Substring(0, $m.Index) + $tag + $Content.Substring($m.Index + $m.Length)
}

function Disable-ServerConfigInstanceId {
    param([string]$Content)
    $m = Find-ServerConfigInstanceIdElement $Content
    if ($null -eq $m) { return $Content }
    return $Content.Substring(0, $m.Index) + '<!-- ' + $m.Value + ' -->' + $Content.Substring($m.Index + $m.Length)
}

function Set-ServerConfigAttribute {
    param([string]$Content, [string]$ElementName, [string]$AttributeName, [string]$Value)
    $pattern = '(<' + [regex]::Escape($ElementName) + '\b[^>]*?\b' + [regex]::Escape($AttributeName) + '=")[^"]*(")'
    if ($Content -notmatch $pattern) { return $null }
    return [regex]::Replace($Content, $pattern, '${1}' + $Value + '${2}')
}

function Set-ServerConfigComServer {
    param([string]$Content, [string]$Tag, [string]$NewProgId, [string]$NewClsid)
    $m = [regex]::Match($Content, ('(<' + [regex]::Escape($Tag) + '\b[^>]*?)/>'))
    if (-not $m.Success) { return $null }
    $inner = $m.Groups[1].Value
    $inner = [regex]::Replace($inner, '\bProgID="[^"]*"', ('ProgID="' + $NewProgId + '"'))
    $inner = [regex]::Replace($inner, '\bCLSID="[^"]*"', ('CLSID="' + $NewClsid + '"'))
    return ($Content.Substring(0, $m.Index) + $inner + '/>' + $Content.Substring($m.Index + $m.Length))
}

function Stop-ServerCopyServiceByFolder {
    param([string]$FolderPath)
    $name = ''
    $wasRunning = $false
    $inst = Get-ServerInstanceFromFolder $FolderPath
    if ($null -ne $inst -and $inst.ServiceName -and $inst.ServiceExists) { $name = $inst.ServiceName }
    if ($name) {
        $svcObj = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svcObj -and $svcObj.Status -ne 'Stopped') {
            $wasRunning = $true
            Write-Log ('Stopping service: ' + $name)
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
    }
    return [pscustomobject]@{ ServiceName = $name; WasRunning = $wasRunning }
}

function Start-ServerCopyServiceByFolder {
    param([object]$StopState)
    if ($null -eq $StopState -or -not $StopState.WasRunning -or -not $StopState.ServiceName) { return }
    $svcObj = Get-Service -Name $StopState.ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $svcObj -and $svcObj.Status -eq 'Stopped') {
        Start-Service -Name $StopState.ServiceName -ErrorAction SilentlyContinue
        Write-Log ('Service started: ' + $StopState.ServiceName)
    }
}

function Invoke-ServerInstaller {
    param(
        [string]$ServerFolder,
        [string]$Switch,
        [int]$TimeoutSeconds = 300
    )
    $installer = Join-Path $ServerFolder (Get-ServerCopyInstallerExeName)
    if (-not (Test-Path $installer)) {
        return [pscustomobject]@{ ExitCode = 9998; TimedOut = $false; Error = 'Server installer not found: ' + $installer }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $installer
    $psi.Arguments = $Switch
    $psi.WorkingDirectory = $ServerFolder
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ ExitCode = 9998; TimedOut = $false; Error = $_.Exception.Message }
    }
    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = 9999; TimedOut = $true; Error = 'Server installer timed out' }
    }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; TimedOut = $false; Error = '' }
}

function New-AdditionalServerCopy {
    param(
        [string]$SourceFolder,
        [string]$TargetFolder,
        [string]$ServiceName,
        [string]$InstanceId,
        [int]$Port,
        [string]$NewProgIdSuffix,
        [switch]$WhatIf
    )
    if (-not (Test-ServerCopyPath $SourceFolder)) {
        throw 'Source server folder is not a valid SePlatform.Data Server installation: ' + $SourceFolder
    }
    if (Test-Path $TargetFolder) {
        throw 'Target folder already exists: ' + $TargetFolder
    }
    $instances = Get-SePlatformServerInstances
    foreach ($i in $instances) {
        if ($i.ServiceName -eq $ServiceName) { throw 'Service name already in use: ' + $ServiceName }
        if ($i.Port -eq ([string]$Port)) { throw 'Port already in use by server: ' + $i.Port }
        if ($i.InstanceId -and $i.InstanceId -eq $InstanceId) { throw 'Instance ID already in use' }
    }
    if (-not (Test-AdditionalServerPortFree $Port)) { throw 'TCP port is already in use: ' + $Port }
    if (-not (Test-AdditionalServerInstanceIdFree $InstanceId)) { throw 'Instance ID is already in use by another copy' }

    Write-Log ('Copying server folder: ' + $SourceFolder + ' -> ' + $TargetFolder)
    $session = @{
        SourceFolder = $SourceFolder
        TargetFolder = $TargetFolder
        ServiceName  = $ServiceName
        InstanceId   = $InstanceId
        Port         = $Port
        NewProgIdSuffix = $NewProgIdSuffix
    }
    if (-not $WhatIf) {
        $stop = Stop-ServerCopyServiceByFolder -FolderPath $SourceFolder
        try {
            Copy-Item -Path $SourceFolder -Destination $TargetFolder -Recurse -Force -ErrorAction Stop

            $sub = Get-ServerCopySubDir
            $cfgPath = Join-Path $TargetFolder (Join-Path $sub (Get-ServerCopyConfigFileName))
            $content = Read-ServerConfigFile $cfgPath

            $updated = Set-ServerConfigAttribute $content 'install' 'ServiceName' $ServiceName
            if ($null -eq $updated) { throw 'Cannot locate install/ServiceName in config XML' }
            $content = $updated

            $updated = Set-ServerConfigAttribute $content 'Connection' 'Port' ([string]$Port)
            if ($null -eq $updated) { throw 'Cannot locate Connection/Port in config XML' }
            $content = $updated

            $updated = Set-ServerConfigInstanceId $content $InstanceId
            if ($null -ne $updated) {
                $content = $updated
            } else {
                Write-Log 'Config XML has no Instance/ID (new-style config); instance ID stored in JSON'
            }

            if (-not (Get-ServerCopyDisableProgIdRewrite)) {
                $cfg = Read-ServerConfigDom $cfgPath
                foreach ($c in $cfg.ComServers) {
                    if (-not $c.ProgID) { continue }
                    $base = $c.ProgID
                    if ($base -match '^(.+?)\.\d+$') { $base = $Matches[1] }
                    $newProgId = $base + '.' + $NewProgIdSuffix
                    $newClsid = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
                    $updatedCom = Set-ServerConfigComServer $content $c.Tag $newProgId $newClsid
                    if ($null -ne $updatedCom) { $content = $updatedCom }
                    Write-Log ('COM server ' + $c.Tag + ': ProgID=' + $newProgId + ' CLSID=' + $newClsid)
                }
            } else {
                Write-Log 'disableProgIdRewrite: keeping existing ProgID/CLSID values'
            }

            Write-ServerConfigFile $cfgPath $content
            Write-Log ('Config updated: ' + $cfgPath)

            $jsonPath = Join-Path $TargetFolder (Join-Path $sub (Get-ServerCopyJsonFileName))
            Write-ServerInstanceIdToJson -Path $jsonPath -InstanceId $InstanceId
            Write-Log ('Instance ID written to ' + $jsonPath)

            $serverDir = Join-Path $TargetFolder $sub
            $reg = Invoke-ServerInstaller -ServerFolder $serverDir -Switch '/install' -TimeoutSeconds (Get-ServerCopyTimeoutSeconds)
            if ($reg.ExitCode -ne 0) { throw 'Server registration failed with exit code ' + $reg.ExitCode }
            Write-Log 'Server registered via ServerInstaller.exe /install'

            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.Status -eq 'Stopped') {
                Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
                Write-Log ('Service started: ' + $ServiceName)
            }
        } finally {
            Start-ServerCopyServiceByFolder $stop
        }
    }
    $script:ServerCopiesState.Results += [pscustomobject]@{
        Action       = 'INSTALL'
        Status       = if ($WhatIf) { 'PENDING' } else { 'OK' }
        FolderName   = Split-Path -Leaf $TargetFolder
        ServiceName  = $ServiceName
        Port         = $Port
        InstanceId   = $InstanceId
        Error        = ''
    }
    return $session
}

function Update-AdditionalServerCopy {
    param(
        [object]$Instance,
        [string]$SourceFolder,
        [switch]$WhatIf
    )
    $mainConfig = Get-SePlatformServerInstances | Where-Object { $_.IsMain }
    if ($null -eq $mainConfig -or $mainConfig.Count -eq 0) {
        throw 'Main SePlatform.Data Server installation not found: cannot determine source version.'
    }
    if (-not (Test-ServerCopyPath $SourceFolder)) { throw 'Source server folder is invalid: ' + $SourceFolder }
    if (-not (Test-ServerCopyPath $Instance.FolderPath)) { throw 'Instance server folder is invalid: ' + $Instance.FolderPath }

    Write-Log ('Updating additional copy ' + $Instance.ServiceName + ' at ' + $Instance.FolderPath)
    $session = @{
        Instance = $Instance
        SourceFolder = $SourceFolder
    }
    if (-not $WhatIf) {
        $stopSource = Stop-ServerCopyServiceByFolder -FolderPath $SourceFolder
        $stopTarget = Stop-ServerCopyServiceByFolder -FolderPath $Instance.FolderPath
        try {
            $sub = Get-ServerCopySubDir
            $srcServer = Join-Path $SourceFolder $sub
            $dstServer = Join-Path $Instance.FolderPath $sub
            $cfgName = Get-ServerCopyConfigFileName
            $jsonName = Get-ServerCopyJsonFileName
            $dstCfgPath = Join-Path $dstServer $cfgName
            $dstJsonPath = Join-Path $dstServer $jsonName
            $srcJsonPath = Join-Path $srcServer $jsonName

            $newStyle = Test-Path $srcJsonPath
            $copyInstanceId = Read-ServerInstanceIdFromJson $dstJsonPath
            if (-not $copyInstanceId -and (Test-Path $dstCfgPath)) {
                $copyInstanceId = [string](Read-ServerConfigDom $dstCfgPath).InstanceId
            }

            $srcFiles = @(Get-ChildItem -Path $srcServer -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($sf in $srcFiles) {
                if ($sf.Name -eq $cfgName -or $sf.Name -eq $jsonName) { continue }
                $rel = $sf.FullName.Substring($srcServer.Length).TrimStart('\')
                $dstFile = Join-Path $dstServer $rel
                try {
                    $destDir = Split-Path -Parent $dstFile
                    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null }
                    Copy-Item -Path $sf.FullName -Destination $dstFile -Force -ErrorAction Stop
                } catch {
                    Write-Log ('File copy failed: ' + $rel + ' - ' + $_.Exception.Message) -Level 'WARN'
                }
            }
            Write-Log ('Binaries synced from ' + $srcServer)

            if ($newStyle) {
                if ($copyInstanceId) {
                    Write-ServerInstanceIdToJson -Path $dstJsonPath -InstanceId $copyInstanceId
                    Write-Log ('Instance ID preserved in ' + $dstJsonPath)
                    if (Test-Path $dstCfgPath) {
                        $xmlContent = Read-ServerConfigFile $dstCfgPath
                        $migrated = Disable-ServerConfigInstanceId $xmlContent
                        if ($migrated -ne $xmlContent) {
                            Write-ServerConfigFile $dstCfgPath $migrated
                            Write-Log 'Legacy Instance/ID in config XML commented out (migrated to JSON)'
                        }
                    }
                } else {
                    Write-Log 'No instance ID found in copy config; keeping existing config files' -Level 'WARN'
                }
            } else {
                Write-Log 'Main server uses legacy (XML) config; instance ID left in XML'
            }

            $srcInstaller = Join-Path $srcServer (Get-ServerCopyInstallerExeName)
            if (Test-Path $srcInstaller) {
                Copy-Item -Path $srcInstaller -Destination (Join-Path $dstServer (Get-ServerCopyInstallerExeName)) -Force -ErrorAction SilentlyContinue
            }

            $reg = Invoke-ServerInstaller -ServerFolder $dstServer -Switch '/install' -TimeoutSeconds (Get-ServerCopyTimeoutSeconds)
            if ($reg.ExitCode -ne 0) { throw 'Server re-registration failed with exit code ' + $reg.ExitCode }
            Write-Log 'Server re-registered via ServerInstaller.exe /install'

            $svc = Get-Service -Name $Instance.ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.Status -eq 'Stopped') {
                Start-Service -Name $Instance.ServiceName -ErrorAction SilentlyContinue
                Write-Log ('Service started: ' + $Instance.ServiceName)
            }
        } finally {
            Start-ServerCopyServiceByFolder $stopTarget
            Start-ServerCopyServiceByFolder $stopSource
        }
    }
    $script:ServerCopiesState.Results += [pscustomobject]@{
        Action       = 'UPDATE'
        Status       = if ($WhatIf) { 'PENDING' } else { 'OK' }
        FolderName   = $Instance.FolderName
        ServiceName  = $Instance.ServiceName
        Port         = $Instance.Port
        InstanceId   = $Instance.InstanceId
        Error        = ''
    }
    return $session
}

function Remove-AdditionalServerCopy {
    param(
        [object]$Instance,
        [switch]$WhatIf
    )
    if ($Instance.IsMain) { throw 'Refusing to remove the main SePlatform.Data Server installation via additional-copy manager.' }
    if (-not (Test-ServerCopyPath $Instance.FolderPath)) { throw 'Instance server folder is invalid: ' + $Instance.FolderPath }

    Write-Log ('Removing additional copy ' + $Instance.ServiceName + ' at ' + $Instance.FolderPath)
    $session = @{ Instance = $Instance }
    if (-not $WhatIf) {
        if ($Instance.ServiceExists) {
            $svc = Get-Service -Name $Instance.ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.Status -ne 'Stopped') {
                Write-Log ('Stopping service: ' + $Instance.ServiceName)
                Stop-Service -Name $Instance.ServiceName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }

        $sub = Get-ServerCopySubDir
        $serverDir = Join-Path $Instance.FolderPath $sub
        if ($Instance.ServiceExists -and (Test-Path (Join-Path $serverDir (Get-ServerCopyInstallerExeName)))) {
            Write-Log ('Running installer /uninstall at: ' + $serverDir)
            $unreg = Invoke-ServerInstaller -ServerFolder $serverDir -Switch '/uninstall' -TimeoutSeconds (Get-ServerCopyTimeoutSeconds)
            if ($unreg.ExitCode -ne 0) {
                Write-Log ('Installer /uninstall returned exit code ' + $unreg.ExitCode) -Level 'WARN'
            }
        }

        if ($Instance.ServiceExists) {
            $svc = Get-Service -Name $Instance.ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $svc) {
                Write-Log ('Deleting service: ' + $Instance.ServiceName)
                try {
                    $p = Start-Process -FilePath 'sc.exe' -ArgumentList 'delete', ('"' + $Instance.ServiceName + '"') -NoNewWindow -Wait -PassThru -ErrorAction Stop
                    Write-Log ('sc delete exit code: ' + $p.ExitCode)
                } catch {
                    Write-Log ('sc delete failed: ' + $_.Exception.Message) -Level 'WARN'
                }
            }
        } else {
            Write-Log ('Service ' + $Instance.ServiceName + ' is not bound to this copy folder; skipping uninstall/delete.') -Level 'WARN'
        }

        Write-Log ('Removing folder: ' + $Instance.FolderPath)
        Remove-Item -Path $Instance.FolderPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:ServerCopiesState.Results += [pscustomobject]@{
        Action       = 'REMOVE'
        Status       = if ($WhatIf) { 'PENDING' } else { 'OK' }
        FolderName   = $Instance.FolderName
        ServiceName  = $Instance.ServiceName
        Port         = $Instance.Port
        InstanceId   = $Instance.InstanceId
        Error        = ''
    }
    return $session
}

function Get-ServerCopyInventory {
    $instances = Get-SePlatformServerInstances
    return ,($instances | ForEach-Object {
        [pscustomobject]@{
            ServiceName = $_.ServiceName
            Port        = $_.Port
            InstanceId  = $_.InstanceId
            Folder      = $_.FolderPath
            IsMain      = $_.IsMain
            State       = $_.ServiceState
        }
    })
}

function Get-NextServerCopyNumber {
    param([object[]]$Instances)
    $max = 0
    foreach ($i in $Instances) {
        if ($i.IsMain) { continue }
        if ($i.FolderName -match '^(.+?)(\d+)$') {
            $n = [int]$Matches[2]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ($max + 1)
}

function Get-SuggestedServerPort {
    param([object[]]$Instances)
    $used = @($Instances | ForEach-Object { $_.Port } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $p = 4573
    while ($p -lt 65535) {
        if (($p -notin $used) -and (Test-AdditionalServerPortFree $p)) { return $p }
        $p++
    }
    return $p
}

function Show-ServerInstancesTable {
    param([object[]]$Instances)
    Write-Host ''
    Write-Host 'SePlatform.Data Server copies (detected):'
    Write-Host ''
    if ($Instances.Count -eq 0) {
        Write-Host '  None found.' -ForegroundColor Yellow
        Write-Host ''
        return
    }
    $i = 1
    foreach ($inst in $Instances) {
        $tag = if ($inst.IsMain) { 'MAIN' } else { 'COPY' }
        $line = ('  [{0}] {1} ({2})  service={3}  port={4}' -f $i, $inst.FolderName, $tag, $inst.ServiceName, $inst.Port)
        if ($inst.ServiceExists) { $line += '  [' + $inst.ServiceState + ']' } else { $line += '  [service not installed]' }
        Write-Host $line
        if ($inst.IsMain) { Write-Host '        (main server, managed by MSI deployment)' }
        $i++
    }
    Write-Host ''
}

function Invoke-ServerCopyInstall {
    $instances = Get-SePlatformServerInstances
    $main = @($instances | Where-Object { $_.IsMain })
    if ($main.Count -eq 0) {
        Write-Host 'ERROR: main SePlatform.Data Server installation not found.' -ForegroundColor Red
        Write-Host 'The main server must be installed first (via standard MSI deployment).' -ForegroundColor Yellow
        return
    }
    $source = $main[0].FolderPath
    $nextNum = Get-NextServerCopyNumber $instances
    $defName = (Get-ServerCopyMainFolderName) + $nextNum
    Write-Host ''
    Write-Host -NoNewline ('Folder name for new copy [default: ' + $defName + ']: ')
    $folderName = (Read-Host).Trim()
    if (-not $folderName) { $folderName = $defName }
    $target = Join-Path (Get-ServerCopyRoot) $folderName
    if (Test-Path $target) {
        Write-Host ('ERROR: target folder already exists: ' + $target) -ForegroundColor Red
        return
    }
    $defSvc = $folderName
    Write-Host -NoNewline ('Service name [default: ' + $defSvc + ']: ')
    $svcName = (Read-Host).Trim()
    if (-not $svcName) { $svcName = $defSvc }
    $defPort = Get-SuggestedServerPort $instances
    Write-Host -NoNewline ('TCP port [default: ' + $defPort + ']: ')
    $portInput = (Read-Host).Trim()
    $port = if ($portInput) { [int]$portInput } else { $defPort }
    $instId = [guid]::NewGuid().ToString().ToUpperInvariant()

    Write-Host ''
    Write-Host 'Plan for new additional copy:'
    Write-Host ('  Source : ' + $source)
    Write-Host ('  Target : ' + $target)
    Write-Host ('  Service: ' + $svcName)
    Write-Host ('  Port   : ' + $port)
    Write-Host ('  ID     : ' + $instId)
    Write-Host ''
    if (-not (Ask-YesNo 'Install additional copy')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
    try {
        $null = New-AdditionalServerCopy -SourceFolder $source -TargetFolder $target -ServiceName $svcName -InstanceId $instId -Port $port -NewProgIdSuffix ([string]$nextNum)
        Write-Host ('  [OK] Additional copy installed: ' + $folderName) -ForegroundColor Green
        $script:Deployment.CountOk++
        Write-Log ('Additional copy installed: ' + $folderName + ' (service ' + $svcName + ', port ' + $port + ')')
    } catch {
        Write-Host ('  [FAIL] ' + $_.Exception.Message) -ForegroundColor Red
        if ($script:Deployment.LogFile) {
            Add-Content -Path $script:Deployment.LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [ERROR] Additional copy install: ' + $_.Exception.Message) -Encoding UTF8
        }
        $script:Deployment.CountFailed++
        if (Test-Path $target) {
            Write-Host '  Partial copy remains at the target folder; review and remove manually if needed.' -ForegroundColor Yellow
        }
    } finally {
        $script:ServerCopiesState.Instances = @()
    }
}

function Invoke-ServerCopyUpdate {
    $instances = Get-SePlatformServerInstances
    $copies = @($instances | Where-Object { -not $_.IsMain })
    if ($copies.Count -eq 0) {
        Write-Host 'No additional copies found to update.' -ForegroundColor Yellow
        return
    }
    $wrapped = @()
    foreach ($c in $copies) {
        $wrapped += [pscustomobject]@{
            DisplayName = ($c.FolderName + '  ' + $c.ServiceName + '  port=' + $c.Port)
            InstalledVersion = ''
            NewVersion = ''
            Source = $c
        }
    }
    $selected = @(Ask-NumberedSelection -Items $wrapped -Title 'Additional copies to update')
    if ($selected.Count -eq 0) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
    $main = @($instances | Where-Object { $_.IsMain })
    if ($main.Count -eq 0) {
        Write-Host 'ERROR: main SePlatform.Data Server installation not found.' -ForegroundColor Red
        return
    }
    $sourceFolder = $main[0].FolderPath
    Write-Host '================================'
    if (-not (Ask-YesNo 'Update selected copies (binaries from main server)')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
    foreach ($sel in $selected) {
        $copy = $sel.Source
        Write-Host ('  Updating ' + $copy.FolderName + '...')
        try {
            $null = Update-AdditionalServerCopy -Instance $copy -SourceFolder $sourceFolder
            Write-Host ('  [OK] Updated: ' + $copy.FolderName) -ForegroundColor Green
            $script:Deployment.CountOk++
            Write-Log ('Additional copy updated: ' + $copy.FolderName + ' (service ' + $copy.ServiceName + ')')
        } catch {
            Write-Host ('  [FAIL] ' + $_.Exception.Message) -ForegroundColor Red
            if ($script:Deployment.LogFile) {
                Add-Content -Path $script:Deployment.LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [ERROR] Additional copy update: ' + $_.Exception.Message) -Encoding UTF8
            }
            $script:Deployment.CountFailed++
        }
    }
    $script:ServerCopiesState.Instances = @()
}

function Invoke-ServerCopyRemove {
    $instances = Get-SePlatformServerInstances
    $copies = @($instances | Where-Object { -not $_.IsMain })
    if ($copies.Count -eq 0) {
        Write-Host 'No additional copies found to remove.' -ForegroundColor Yellow
        return
    }
    $wrapped = @()
    foreach ($c in $copies) {
        $wrapped += [pscustomobject]@{
            DisplayName = ($c.FolderName + '  ' + $c.ServiceName + '  port=' + $c.Port)
            InstalledVersion = ''
            NewVersion = ''
            Source = $c
        }
    }
    $selected = @(Ask-NumberedSelection -Items $wrapped -Title 'Additional copies to REMOVE')
    if ($selected.Count -eq 0) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
    Write-Host '================================'
    if (-not (Ask-YesNo 'Remove selected additional copies (service and folder will be deleted)')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return
    }
    foreach ($sel in $selected) {
        $copy = $sel.Source
        Write-Host ('  Removing ' + $copy.FolderName + '...')
        try {
            $null = Remove-AdditionalServerCopy -Instance $copy
            Write-Host ('  [OK] Removed: ' + $copy.FolderName) -ForegroundColor Green
            $script:Deployment.CountOk++
            Write-Log ('Additional copy removed: ' + $copy.FolderName + ' (service ' + $copy.ServiceName + ')')
        } catch {
            Write-Host ('  [FAIL] ' + $_.Exception.Message) -ForegroundColor Red
            if ($script:Deployment.LogFile) {
                Add-Content -Path $script:Deployment.LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [ERROR] Additional copy remove: ' + $_.Exception.Message) -Encoding UTF8
            }
            $script:Deployment.CountFailed++
        }
    }
    $script:ServerCopiesState.Instances = @()
}

function Manage-AdditionalServerCopies {
    while ($true) {
        $instances = Get-SePlatformServerInstances
        Show-ServerInstancesTable $instances
        Write-Host 'SePlatform.Data Server copies menu:'
        Write-Host '  [1] Install a new additional copy (initial installation)'
        Write-Host '  [2] Update additional copies from the main server'
        Write-Host '  [3] Remove an additional copy'
        Write-Host '  [4] Rescan detected copies'
        Write-Host '  [5] Back'
        Write-Host ''
        Write-Host -NoNewline 'Select: '
        $input = (Read-Host).Trim()
        switch ($input) {
            '1' { Invoke-ServerCopyInstall }
            '2' { Invoke-ServerCopyUpdate }
            '3' { Invoke-ServerCopyRemove }
            '4' { $script:ServerCopiesState.Instances = @() }
            '5' { return }
            default { Write-Host 'Please enter 1-5.' -ForegroundColor Yellow }
        }
    }
}