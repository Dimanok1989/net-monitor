#Requires -Version 5.1
<#
  Мониторинг TCP-соединений Windows.

  Запуск: start-monitor.bat
  Остановка: Ctrl+C

  Логи пишутся в каталог logs рядом с этим файлом.
  На каждое приложение и дату — отдельный файл:
    logs\chrome_2026-11-20.log

  В файле: имя приложения, путь к exe и удалённые адреса
  (IP, порт и домен, если Windows его знает).

  Домен берётся из DNS-кэша системы, затем из обратного DNS.
  Очень короткие соединения между опросами могут не попасть в лог.
#>
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 2,

    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = (Get-Location).Path }

$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$script:apps = @{}
$script:ptrCache = @{}
$script:ptrQueued = @{}
$script:ptrQueuePublic = New-Object 'System.Collections.Generic.Queue[string]'
$script:ptrQueuePrivate = New-Object 'System.Collections.Generic.Queue[string]'
$script:ptrActive = @()
$script:ptrBackground = @()
$script:mutex = $null
$script:alreadyRunning = $false
$script:utf8 = New-Object System.Text.UTF8Encoding $true

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeFileName {
    param([string]$Name)

    $clean = $Name -replace '[<>:"/\\|?*]', '_'
    $clean = ($clean -replace '\s+', '_').Trim(' ._')
    if (-not $clean) { $clean = 'unknown' }

    $reserved = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )
    if ($reserved -contains $clean.ToUpperInvariant()) {
        $clean = "_$clean"
    }
    if ($clean.Length -gt 80) {
        $clean = $clean.Substring(0, 80).Trim(' ._')
    }
    return $clean
}

function ConvertTo-IPString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $raw = $Value.Trim()
    if ($raw.StartsWith('[')) {
        $end = $raw.IndexOf(']')
        if ($end -gt 1) { $raw = $raw.Substring(1, $end - 1) }
    }
    $percent = $raw.IndexOf('%')
    if ($percent -gt 0) { $raw = $raw.Substring(0, $percent) }

    try {
        return ([Net.IPAddress]::Parse($raw)).IPAddressToString
    }
    catch {
        return $null
    }
}

function Test-IgnoredIP {
    param([string]$IP)

    $parsed = [Net.IPAddress]::Parse($IP)
    if ([Net.IPAddress]::IsLoopback($parsed)) { return $true }

    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $parsed.GetAddressBytes()
        if ($bytes[0] -eq 0) { return $true }
        return $false
    }

    $v6 = $parsed.GetAddressBytes()
    $allZero = $true
    foreach ($b in $v6) {
        if ($b -ne 0) { $allZero = $false; break }
    }
    return $allZero
}

function Test-PrivateIP {
    param([string]$IP)

    $parsed = [Net.IPAddress]::Parse($IP)
    $bytes = $parsed.GetAddressBytes()
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        if (($bytes[0] -band 0xFE) -eq 0xFC) { return $true }
        if ($bytes[0] -eq 0xFE -and ($bytes[1] -band 0xC0) -eq 0x80) { return $true }
        return $false
    }

    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $true }
    return $false
}

function Format-Endpoint {
    param(
        [string]$IP,
        [int]$Port
    )

    $parsed = [Net.IPAddress]::Parse($IP)
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return '[{0}]:{1}' -f $parsed.IPAddressToString, $Port
    }
    return '{0}:{1}' -f $parsed.IPAddressToString, $Port
}

function Format-Domain {
    param($Names)

    $unique = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $trimmed = $name.Trim().TrimEnd('.')
        if (-not $trimmed) { continue }
        if ($trimmed -like '*.in-addr.arpa' -or $trimmed -like '*.ip6.arpa') { continue }
        if (-not $unique.Contains($trimmed)) { $unique.Add($trimmed) }
    }
    if ($unique.Count -eq 0) { return $null }

    $picked = $unique | Sort-Object Length, { $_ } | Select-Object -First 3
    return ($picked -join ', ')
}

function Get-LogPath {
    param($App)

    $date = Get-Date -Format 'yyyy-MM-dd'
    return Join-Path $LogDir ('{0}_{1}.log' -f $App.FileName, $date)
}

function Save-AppLog {
    param($App)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# ' + $App.DisplayName) | Out-Null
    if ($App.Paths.Count -eq 0) {
        $lines.Add('# (путь недоступен)') | Out-Null
    }
    else {
        foreach ($path in $App.Paths) {
            $lines.Add('# ' + $path) | Out-Null
        }
    }
    foreach ($ep in $App.Endpoints) {
        if ($ep.Domain) {
            $lines.Add(('{0}    {1}' -f $ep.Text, $ep.Domain)) | Out-Null
        }
        else {
            $lines.Add($ep.Text) | Out-Null
        }
    }

    $target = Get-LogPath $App
    [IO.File]::WriteAllLines($target, $lines.ToArray(), $script:utf8)
}

function Add-AppPath {
    param($App, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($existing in $App.Paths) {
        if ([string]::Equals($existing, $Path, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    $App.Paths.Add($Path) | Out-Null
    return $true
}

function Get-App {
    param(
        [string]$DisplayName,
        [string]$Path
    )

    $fileName = Get-SafeFileName $DisplayName
    $key = $fileName.ToLowerInvariant()
    if (-not $script:apps.ContainsKey($key)) {
        $script:apps[$key] = @{
            FileName    = $fileName
            DisplayName = $DisplayName
            Paths       = New-Object 'System.Collections.Generic.List[string]'
            Endpoints   = New-Object 'System.Collections.Generic.List[object]'
            Index       = @{}
        }
    }

    $app = $script:apps[$key]
    $pathAdded = Add-AppPath $app $Path
    return @{ App = $app; PathAdded = $pathAdded }
}

function Import-TodayLogs {
    $date = Get-Date -Format 'yyyy-MM-dd'
    $pattern = '^(.*)_{0}$' -f [Regex]::Escape($date)
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter "*_$date.log" -File -ErrorAction SilentlyContinue)

    foreach ($file in $files) {
        if ($file.BaseName -notmatch $pattern) { continue }
        $fileName = $Matches[1]
        $key = $fileName.ToLowerInvariant()
        $app = @{
            FileName    = $fileName
            DisplayName = $fileName
            Paths       = New-Object 'System.Collections.Generic.List[string]'
            Endpoints   = New-Object 'System.Collections.Generic.List[object]'
            Index       = @{}
        }

        $fileLines = @([IO.File]::ReadAllLines($file.FullName, $script:utf8))
        $headerSeen = $false
        foreach ($line in $fileLines) {
            $text = $line.Trim()
            if (-not $text) { continue }

            if ($text.StartsWith('#')) {
                $value = $text.Substring(1).Trim()
                if (-not $headerSeen) {
                    if ($value) { $app.DisplayName = $value }
                    $headerSeen = $true
                }
                elseif ($value -and $value -ne '(путь недоступен)' -and $value -match '[\\/]') {
                    Add-AppPath $app $value | Out-Null
                }
                continue
            }

            if ($text -match '^(\[[^\]]+\]|\d{1,3}(?:\.\d{1,3}){3}):(\d+)(?:\s+(\S.*?))?\s*$') {
                $ip = ConvertTo-IPString $Matches[1]
                $port = [int]$Matches[2]
                if (-not $ip -or $port -lt 1 -or $port -gt 65535) { continue }
                $domain = $null
                if ($Matches.ContainsKey(3) -and $Matches[3]) { $domain = ([string]$Matches[3]).Trim() }
                $endpointText = Format-Endpoint $ip $port
                if ($app.Index.ContainsKey($endpointText)) { continue }
                $ep = @{
                    IP     = $ip
                    Port   = $port
                    Text   = $endpointText
                    Domain = $domain
                    Source = $(if ($domain) { 'file' } else { '' })
                }
                $app.Endpoints.Add($ep) | Out-Null
                $app.Index[$endpointText] = $ep
            }
        }

        $script:apps[$key] = $app
    }
}

function Get-ProcessMap {
    $map = @{}
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    foreach ($proc in $processes) {
        $pidValue = [int]$proc.ProcessId
        $display = [IO.Path]::GetFileNameWithoutExtension([string]$proc.Name)
        if ($proc.ExecutablePath) {
            $fromPath = [IO.Path]::GetFileNameWithoutExtension([string]$proc.ExecutablePath)
            if ($fromPath) { $display = $fromPath }
        }
        if (-not $display) { $display = "pid-$pidValue" }

        $command = [string]$proc.CommandLine
        if ([string]$proc.Name -eq 'svchost.exe' -and $command -match '(?i)(?:^|\s)-s\s+"?([^"\s]+)') {
            $display = 'svchost ({0})' -f $Matches[1]
        }

        $map[$pidValue] = @{
            DisplayName = $display
            Path        = [string]$proc.ExecutablePath
        }
    }
    return $map
}

function Get-DnsMap {
    $map = @{}
    $entries = @()
    try {
        $entries = @(Get-DnsClientCache -ErrorAction Stop)
    }
    catch {
        return $map
    }

    foreach ($entry in $entries) {
        $status = [string]$entry.Status
        if ($status -and $status -ne '0' -and $status -ne 'Success') { continue }

        $ip = ConvertTo-IPString ([string]$entry.Data)
        if (-not $ip) { continue }

        $name = [string]$entry.Entry
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $name = $name.Trim().TrimEnd('.')
        if (-not $name -or $name -eq $ip) { continue }
        if ($name -like '*.in-addr.arpa' -or $name -like '*.ip6.arpa') { continue }

        if (-not $map.ContainsKey($ip)) {
            $map[$ip] = New-Object 'System.Collections.Generic.List[string]'
        }
        if (-not $map[$ip].Contains($name)) {
            $map[$ip].Add($name)
        }
    }
    return $map
}

function Get-TcpSnapshot {
    $listening = @{}
    $connections = New-Object 'System.Collections.Generic.List[object]'
    $raw = @(& netstat.exe -ano -p tcp)

    foreach ($line in $raw) {
        if ($line -notmatch '^\s*TCP\s+(\[[^\]]+\]|\d+\.\d+\.\d+\.\d+):(\d+)\s+(\[[^\]]+\]|\d+\.\d+\.\d+\.\d+):(\d+)\s+\S+\s+(\d+)\s*$') {
            continue
        }

        $localPort = [int]$Matches[2]
        $remoteIp = ConvertTo-IPString $Matches[3]
        $remotePort = [int]$Matches[4]
        $processId = [int]$Matches[5]
        if (-not $remoteIp) { continue }

        $isListening = $remotePort -eq 0 -or $remoteIp -eq '0.0.0.0' -or $remoteIp -eq '::'
        if ($isListening) {
            if ($processId -gt 0 -and $localPort -gt 0) {
                $listening["$processId|$localPort"] = $true
            }
            continue
        }

        try {
            if (Test-IgnoredIP $remoteIp) { continue }
        }
        catch {
            continue
        }

        $connections.Add(@{
            ProcessId  = $processId
            LocalPort  = $localPort
            RemoteIP   = $remoteIp
            RemotePort = $remotePort
        }) | Out-Null
    }

    return @{
        Listening   = $listening
        Connections = $connections
    }
}

function Write-Event {
    param(
        [string]$Name,
        [string]$Endpoint,
        [string]$Domain
    )

    $time = Get-Date -Format 'HH:mm:ss'
    if ($Domain) {
        Write-Host ("{0}  {1}  {2}  {3}" -f $time, $Name, $Endpoint, $Domain)
    }
    else {
        Write-Host ("{0}  {1}  {2}" -f $time, $Name, $Endpoint)
    }
}

function Set-EndpointDomain {
    param(
        $Endpoint,
        [string]$Domain,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Domain)) { return $false }
    if ($Endpoint.Source -eq 'cache' -and $Endpoint.Domain) { return $false }
    if ($Source -ne 'cache' -and $Endpoint.Domain) { return $false }
    if ($Endpoint.Domain -eq $Domain) {
        $Endpoint.Source = $Source
        return $false
    }

    $Endpoint.Domain = $Domain
    $Endpoint.Source = $Source
    return $true
}

function Update-CachedDomains {
    param($DnsMap)

    foreach ($app in @($script:apps.Values)) {
        $dirty = $false
        foreach ($ep in $app.Endpoints) {
            if (-not $DnsMap.ContainsKey($ep.IP)) { continue }
            $domain = Format-Domain $DnsMap[$ep.IP]
            if (-not $domain) { continue }
            if (Set-EndpointDomain $ep $domain 'cache') {
                $dirty = $true
                Write-Event $app.DisplayName $ep.Text $domain
            }
        }
        if ($dirty) { Save-AppLog $app }
    }
}

function Add-ObservedConnection {
    param(
        $ProcessInfo,
        [string]$IP,
        [int]$Port,
        $DnsMap
    )

    $found = Get-App $ProcessInfo.DisplayName $ProcessInfo.Path
    $app = $found.App
    $text = Format-Endpoint $IP $Port
    $dirty = $found.PathAdded
    $isNew = $false

    if (-not $app.Index.ContainsKey($text)) {
        $ep = @{
            IP     = $IP
            Port   = $Port
            Text   = $text
            Domain = $null
            Source = ''
        }
        $app.Endpoints.Add($ep) | Out-Null
        $app.Index[$text] = $ep
        $dirty = $true
        $isNew = $true
    }

    $ep = $app.Index[$text]
    $domain = $null
    if ($DnsMap.ContainsKey($IP)) {
        $domain = Format-Domain $DnsMap[$IP]
        if ($domain -and (Set-EndpointDomain $ep $domain 'cache')) {
            $dirty = $true
        }
    }

    if ($dirty) { Save-AppLog $app }
    if ($isNew) { Write-Event $app.DisplayName $text $ep.Domain }

    if (-not $ep.Domain -and -not $script:ptrCache.ContainsKey($IP) -and -not $script:ptrQueued.ContainsKey($IP)) {
        if (Test-PrivateIP $IP) { $script:ptrQueuePrivate.Enqueue($IP) }
        else { $script:ptrQueuePublic.Enqueue($IP) }
        $script:ptrQueued[$IP] = $true
    }
}

function Apply-ResolvedDomain {
    param(
        [string]$IP,
        [string]$Domain,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Domain)) { return }
    foreach ($app in @($script:apps.Values)) {
        $dirty = $false
        foreach ($ep in $app.Endpoints) {
            if ($ep.IP -ne $IP) { continue }
            if (Set-EndpointDomain $ep $Domain $Source) {
                $dirty = $true
                Write-Event $app.DisplayName $ep.Text $Domain
            }
        }
        if ($dirty) { Save-AppLog $app }
    }
}

function Complete-PtrLookup {
    param($Item)

    $domain = $null
    try {
        $result = @($Item.PowerShell.EndInvoke($Item.Handle))
        if ($result.Count -gt 0 -and $result[0]) {
            $domain = ([string]$result[0]).Trim().TrimEnd('.')
            if ($domain -eq $Item.IP) { $domain = $null }
        }
    }
    catch {
        $domain = $null
    }
    finally {
        $Item.PowerShell.Dispose()
    }

    $script:ptrCache[$Item.IP] = $domain
    Apply-ResolvedDomain $Item.IP $domain 'ptr'
}

function Receive-PtrResults {
    $stillActive = @()
    $stillBackground = @()

    foreach ($item in @($script:ptrActive)) {
        if ($item.Handle.IsCompleted) {
            Complete-PtrLookup $item
            continue
        }
        if (((Get-Date) - $item.Started).TotalSeconds -ge 4) {
            $stillBackground += $item
        }
        else {
            $stillActive += $item
        }
    }

    foreach ($item in @($script:ptrBackground)) {
        if ($item.Handle.IsCompleted) {
            Complete-PtrLookup $item
        }
        else {
            $stillBackground += $item
        }
    }

    $script:ptrActive = $stillActive
    $script:ptrBackground = $stillBackground
}

function Start-PtrLookups {
    while ($script:ptrActive.Count -lt 6 -and ($script:ptrQueuePublic.Count -gt 0 -or $script:ptrQueuePrivate.Count -gt 0)) {
        if (($script:ptrActive.Count + $script:ptrBackground.Count) -ge 12) { break }
        if ($script:ptrQueuePublic.Count -gt 0) { $ip = $script:ptrQueuePublic.Dequeue() }
        else { $ip = $script:ptrQueuePrivate.Dequeue() }
        if ($script:ptrCache.ContainsKey($ip)) { continue }

        $lookup = [powershell]::Create()
        [void]$lookup.AddScript({
            param($Address)
            try {
                $hostName = [Net.Dns]::GetHostEntry($Address).HostName
                if ($hostName) { return [string]$hostName }
            }
            catch { }
            return $null
        }).AddArgument($ip)

        $script:ptrActive += @{
            IP         = $ip
            PowerShell = $lookup
            Handle     = $lookup.BeginInvoke()
            Started    = Get-Date
        }
    }
}

function Stop-PtrLookups {
    foreach ($item in @($script:ptrActive + $script:ptrBackground)) {
        if ($item.Handle.IsCompleted) {
            try { $item.PowerShell.Dispose() } catch { }
        }
    }
    $script:ptrActive = @()
    $script:ptrBackground = @()
}

function Queue-UnresolvedDomains {
    foreach ($app in $script:apps.Values) {
        foreach ($ep in $app.Endpoints) {
            if ($ep.Domain) { continue }
            if ($script:ptrCache.ContainsKey($ep.IP)) { continue }
            if ($script:ptrQueued.ContainsKey($ep.IP)) { continue }
            if (Test-PrivateIP $ep.IP) { $script:ptrQueuePrivate.Enqueue($ep.IP) }
            else { $script:ptrQueuePublic.Enqueue($ep.IP) }
            $script:ptrQueued[$ep.IP] = $true
        }
    }
}

function Invoke-MonitorPass {
    $processes = Get-ProcessMap
    $dnsMap = Get-DnsMap
    Receive-PtrResults
    Update-CachedDomains $dnsMap
    Queue-UnresolvedDomains

    $snapshot = Get-TcpSnapshot
    foreach ($conn in $snapshot.Connections) {
        if ($conn.ProcessId -le 0) { continue }
        $listenKey = '{0}|{1}' -f $conn.ProcessId, $conn.LocalPort
        if ($snapshot.Listening.ContainsKey($listenKey)) { continue }
        if (-not $processes.ContainsKey($conn.ProcessId)) { continue }

        Add-ObservedConnection $processes[$conn.ProcessId] $conn.RemoteIP $conn.RemotePort $dnsMap
    }

    Start-PtrLookups
}

try {
    $createdNew = $false
    try {
        $script:mutex = New-Object System.Threading.Mutex($false, 'Local\NetMonitor.SingleInstance', [ref]$createdNew)
        if (-not $createdNew) {
            $script:alreadyRunning = $true
            Write-Host 'Мониторинг уже запущен в другом окне.'
            $script:mutex.Dispose()
            $script:mutex = $null
            return
        }
    }
    catch {
        Write-Host 'Не удалось проверить, что запущен только один экземпляр. Продолжаю.'
    }

    Import-TodayLogs

    $isAdmin = Test-IsAdmin
    Write-Host 'Мониторинг сети запущен.'
    Write-Host ("Логи: {0}" -f $LogDir)
    Write-Host ("Интервал: {0} сек. Остановка: Ctrl+C" -f $IntervalSeconds)
    if (-not $isAdmin) {
        Write-Host 'Без прав администратора видны не все приложения, а домены из DNS-кэша могут отсутствовать.'
        Write-Host 'Запустите start-monitor.bat — он запросит права администратора.'
    }
    Write-Host ''

    do {
        try {
            Invoke-MonitorPass
        }
        catch {
            Write-Host ("Ошибка опроса: {0}" -f $_.Exception.Message)
        }
        if ($Once) { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)

    if ($Once) {
        $deadline = (Get-Date).AddSeconds(8)
        do {
            Receive-PtrResults
            Start-PtrLookups
            $busy = $script:ptrActive.Count -gt 0 -or $script:ptrBackground.Count -gt 0 -or $script:ptrQueuePublic.Count -gt 0 -or $script:ptrQueuePrivate.Count -gt 0
            if (-not $busy -or (Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 150
        } while ($true)
        Receive-PtrResults
    }
}
finally {
    Stop-PtrLookups
    if ($script:mutex) {
        $script:mutex.Dispose()
        $script:mutex = $null
    }
    if (-not $script:alreadyRunning) {
        Write-Host ''
        Write-Host 'Мониторинг остановлен.'
    }
    # Фоновые DNS-запросы не прерываются сами. Выход из процесса отпускает их сразу.
    $exitCode = 0
    if ($script:alreadyRunning) { $exitCode = 1 }
    [Environment]::Exit($exitCode)
}
