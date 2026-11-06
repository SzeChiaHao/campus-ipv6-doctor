<#
.SYNOPSIS
  校园网 IPv6 体检 —— 判断你这条链路到底有没有 IPv6，以及卡在哪一层。

.DESCRIPTION
  很多"校园网没有 IPv6"其实是本机没开。这个脚本按 5 层逐层判定，
  把"本机没开"和"上游没给"分开，避免对着上游白折腾。

  L0 协议栈  Windows 是否全局禁用 IPv6（DisabledComponents）
  L1 网卡    每张网卡的 IPv6 协议是否绑定（ms_tcpip6）—— 最常见的坑
  L2 链路    是否收到路由器通告（表现为 ::/0 默认路由）
  L3 地址    是否拿到全局地址（2000::/3，排除 fe80::/10）
  L4 出口    是否真的能出网（ICMP + TCP）

.PARAMETER Json
  输出 JSON，便于机器处理。

.PARAMETER Router
  额外探测网关路由器：抓 TP-Link / 水星 / 迅捷类 dynaform 固件的
  界面文案（/language/cn/str.js），统计 ipv6 出现次数。
  次数为 0 = 该固件根本没有 IPv6 模块，原厂无解。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ipv6-doctor.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ipv6-doctor.ps1 -Router

.NOTES
  只读脚本，不需要管理员权限，不修改任何系统设置。
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Router,

    # 显式指定要探测的路由器地址（例如路由器后台的 192.168.1.1）。
    # 不填则探测 IPv4 默认网关；校园网网关通常不开放 80 端口，需要手动指定。
    [string]$ProbeHost
)

$ErrorActionPreference = 'SilentlyContinue'
$script:result = [ordered]@{}
$script:lines  = New-Object System.Collections.Generic.List[object]

function Add-Line {
    param([string]$Level, [string]$Layer, [string]$Text)
    $script:lines.Add([pscustomobject]@{ level = $Level; layer = $Layer; text = $Text })
    if (-not $Json) {
        $tag = switch ($Level) {
            'ok'   { '[ OK ]' }
            'warn' { '[WARN]' }
            'bad'  { '[FAIL]' }
            default { '[ .. ]' }
        }
        $color = switch ($Level) {
            'ok'   { 'Green' }
            'warn' { 'Yellow' }
            'bad'  { 'Red' }
            default { 'Gray' }
        }
        $prefix = if ($Layer) { " $tag $Layer  " } else { " $tag  " }
        Write-Host $prefix -NoNewline -ForegroundColor $color
        Write-Host $Text
    }
}

function Section {
    param([string]$Title)
    if (-not $Json) { Write-Host ""; Write-Host ("=== " + $Title + " " + ("=" * [Math]::Max(0, 56 - $Title.Length))) -ForegroundColor Cyan }
}

# ---------------------------------------------------------------- 基础
Section "环境"
$os = (Get-CimInstance Win32_OperatingSystem)
$script:result.os        = "$($os.Caption) $($os.Version)"
$script:result.psVersion = $PSVersionTable.PSVersion.ToString()
$script:result.time      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
if (-not $Json) {
    Write-Host ("  OS        : " + $script:result.os)
    Write-Host ("  PowerShell: " + $script:result.psVersion)
    Write-Host ("  时间      : " + $script:result.time)
}

# ---------------------------------------------------------------- L0
Section "L0 协议栈层：Windows 有没有全局禁用 IPv6"
$dc = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents).DisabledComponents
if ($null -eq $dc) { $dc = 0 }
$script:result.disabledComponents = $dc
if ($dc -eq 0) {
    Add-Line 'ok' 'L0' 'DisabledComponents = 0，IPv6 协议栈未被全局禁用'
    $l0 = $true
} else {
    Add-Line 'bad' 'L0' ("DisabledComponents = 0x{0:X}，IPv6 被策略禁用（常见值 0xFF / 0x20）" -f $dc)
    Add-Line 'warn' 'L0' '修复：以管理员运行  ipv6-doctor-fix.ps1'
    $l0 = $false
}

# ---------------------------------------------------------------- L1
Section "L1 网卡层：每张网卡的 IPv6 协议有没有绑定"
$bind = Get-NetAdapterBinding -ComponentID 'ms_tcpip6'
$adapters = Get-NetAdapter | Sort-Object ifIndex
$nicRows = @()
foreach ($a in $adapters) {
    $b = $bind | Where-Object { $_.Name -eq $a.Name }
    $enabled = if ($null -ne $b) { [bool]$b.Enabled } else { $false }
    $nicRows += [pscustomobject]@{
        ifIndex = $a.ifIndex
        name    = $a.Name
        status  = [string]$a.Status
        speed   = [string]$a.LinkSpeed
        ipv6Bound = $enabled
    }
    if ($a.Status -ne 'Up') { continue }
    if ($enabled) {
        Add-Line 'ok' 'L1' ("{0}（ifIndex {1}，{2}）IPv6 已绑定" -f $a.Name, $a.ifIndex, $a.LinkSpeed)
    } else {
        Add-Line 'bad' 'L1' ("{0}（ifIndex {1}）IPv6 未绑定 —— 这张卡压根不跑 IPv6，测什么都测不到" -f $a.Name, $a.ifIndex)
    }
}
$script:result.adapters = $nicRows

$upNics     = @($nicRows | Where-Object { $_.status -eq 'Up' })
$upNicsV6   = @($upNics   | Where-Object { $_.ipv6Bound })
$l1 = ($upNicsV6.Count -gt 0)
if (-not $l1) {
    Add-Line 'bad' 'L1' '没有任何一张已连接的网卡绑定了 IPv6 —— 这就是"本机没开"，先修这里'
}

# ---------------------------------------------------------------- 无线信息
$wlanLines = @()
$wlanOut = netsh wlan show interfaces 2>$null
foreach ($l in $wlanOut) {
    if ($l -match '^\s*(SSID|BSSID|状态|State|信号|Signal)\s*[:：]\s*(.+)$') {
        $wlanLines += ($Matches[1] + ' : ' + $Matches[2].Trim())
    }
}
$script:result.wireless = $wlanLines
if ($wlanLines.Count -gt 0) {
    Section "无线链路"
    foreach ($l in $wlanLines) { Write-Host ("  " + $l) }
    if (-not $Json) { Write-Host "  提示：测有线时务必先 netsh wlan disconnect，否则 Windows 可能仍然走无线" -ForegroundColor DarkGray }
} else {
    $script:result.wireless = @('（未连接无线）')
}

# ---------------------------------------------------------------- L2 / L3
Section "L2 链路层：有没有收到路由器通告（RA）"
$defaultRoutes = Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
$script:result.defaultRoutesV6 = @()
if ($defaultRoutes) {
    foreach ($r in $defaultRoutes) {
        $script:result.defaultRoutesV6 += [pscustomobject]@{
            ifIndex = $r.ifIndex; nextHop = $r.NextHop; metric = $r.RouteMetric
        }
        Add-Line 'ok' 'L2' ("有 IPv6 默认路由：::/0 via {0}（ifIndex {1}）" -f $r.NextHop, $r.ifIndex)
    }
    $l2 = $true
} else {
    Add-Line 'bad' 'L2' '没有 ::/0 默认路由 —— 这条链路上从来没收到过路由器通告'
    Add-Line 'info' 'L2' '只有 fe80:: 地址不代表"没 IPv6"；没有 ::/0 才是真的没收到 RA'
    $l2 = $false
}

# 邻居表交叉验证
$nbr = Get-NetNeighbor -AddressFamily IPv6 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -like 'fe80::*' -and $_.State -ne 'Unreachable' }
$script:result.ipv6RouterNeighbors = @($nbr | Select-Object -ExpandProperty IPAddress -Unique)
if (@($nbr).Count -gt 0) {
    Add-Line 'info' 'L2' ("邻居表里有 {0} 个可达的 fe80:: 单播邻居（旁证，不是判据）" -f @($nbr).Count)
} else {
    Add-Line 'info' 'L2' '邻居表里只有 ff02:: 组播 = 从没和任何 IPv6 节点通过信'
}

Section "L3 地址层：有没有全局 IPv6 地址"
$globalAddrs = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike 'fe80::*' -and $_.IPAddress -ne '::1' -and $_.PrefixOrigin -ne 'WellKnown' }
$script:result.globalAddrs = @()
if ($globalAddrs) {
    foreach ($g in $globalAddrs) {
        $script:result.globalAddrs += [pscustomobject]@{
            ifIndex = $g.InterfaceIndex; address = $g.IPAddress; prefix = $g.PrefixLength
            origin = [string]$g.PrefixOrigin; suffix = [string]$g.SuffixOrigin
            validLifetime = [string]$g.ValidLifetime
        }
        Add-Line 'ok' 'L3' ("{0}/{1}（ifIndex {2}，来源 {3}）" -f $g.IPAddress, $g.PrefixLength, $g.InterfaceIndex, $g.PrefixOrigin)
    }
    $l3 = $true
} else {
    Add-Line 'bad' 'L3' '没有全局 IPv6 地址（只有 fe80:: 链路本地）'
    $l3 = $false
}

# 前缀 /64 提示
$raAddrs = $globalAddrs | Where-Object { $_.PrefixOrigin -eq 'RouterAdvertisement' }
if ($raAddrs) {
    $pfx = $raAddrs | Select-Object -First 1
    Add-Line 'info' 'L3' ("前缀由 RA 下发：/{0}（SLAAC）。若要分给局域网设备，路由器必须支持 NDP 中继或 NAPT66" -f $pfx.PrefixLength)
    if ($pfx.PrefixLength -eq 64) {
        Add-Line 'info' 'L3' '上游只给 /64、没给前缀委派（PD）时，原厂家用固件"IPv6 前缀分配"通常无效'
    }
}

# ---------------------------------------------------------------- L4
Section "L4 出口层：能不能真的出网"
$targets = @(
    @{ host = '2400:3200::1';          label = 'AliDNS 2400:3200::1（国内）' },
    @{ host = '240c::6666';            label = '联通DNS 240c::6666（国内）' },
    @{ host = '2001:4860:4860::8888';  label = 'Google DNS（境外，常被墙）' }
)
$l4 = $false
$script:result.icmp = @()
foreach ($t in $targets) {
    $ok = $false
    if ($l3) { $ok = (Test-Connection -ComputerName $t.host -Count 2 -Quiet -ErrorAction SilentlyContinue) }
    $script:result.icmp += [pscustomobject]@{ host = $t.host; reachable = [bool]$ok }
    if ($ok) {
        Add-Line 'ok' 'L4' ("{0} -> 通" -f $t.label)
        # 境外目标只作参考，不计入判定（国内教育网普遍屏蔽谷歌 IPv6）
        if ($t.host -notlike '2001:4860*') { $l4 = $true }
    } else {
        $mark = if ($t.host -like '2001:4860*') { 'warn' } else { 'bad' }
        Add-Line $mark 'L4' ("{0} -> 不通" -f $t.label)
    }
}

$httpOk = $false
if ($l3) {
    try {
        $resp = Invoke-WebRequest -Uri 'https://ipv6.baidu.com/' -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $httpOk = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
    } catch { $httpOk = $false }
}
$script:result.httpV6 = $httpOk
if ($httpOk) { Add-Line 'ok' 'L4' 'https://ipv6.baidu.com/（纯 IPv6 域名）HTTP 通' }
elseif ($l3) { Add-Line 'warn' 'L4' '纯 IPv6 域名 HTTP 不通 —— 可能被认证网关拦截或防火墙拦了' }
if ($httpOk) { $l4 = $true }

# ---------------------------------------------------------------- 路由器探测
$routerInfo = $null
if ($Router) {
    Section "网关路由器探测"
    $gw = @()
    if ($ProbeHost) { $gw = @($ProbeHost) }
    else { $gw = @((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop | Select-Object -Unique) }
    $routerInfo = @()
    foreach ($g in $gw) {
        if (-not $g) { continue }
        $entry = [ordered]@{ gateway = $g; title = ''; ipv6StringCount = $null; menus = @(); verdict = '' }
        try {
            $r = Invoke-WebRequest -Uri ("http://" + $g + "/") -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            $m = [regex]::Match($r.Content, '<title>(.*?)</title>')
            $entry.title = $m.Groups[1].Value
            Add-Line 'info' 'GW' ("{0} -> HTTP {1}，页面 title = {2}" -f $g, $r.StatusCode, $entry.title)
        } catch {
            Add-Line 'info' 'GW' ("{0} -> 拿不到网页（网关可能不开放 80 端口）" -f $g)
        }
        # dynaform 固件（TP-Link / 水星 / 迅捷 / Mercury）界面文案
        foreach ($path in @('/language/cn/str.js', '/language/en/str.js', '/dynaform/menu.js')) {
            try {
                $res = Invoke-WebRequest -Uri ("http://" + $g + $path) -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            } catch { continue }
            if ($res.StatusCode -ne 200 -or $res.Content.Length -lt 200) { continue }
            $body = [string]$res.Content
            if ($path -like '*menu.js*') {
                $menus = [regex]::Matches($body, 'url:"([A-Za-z0-9_]+\.htm)"') | ForEach-Object { $_.Groups[1].Value }
                $entry.menus = @($menus | Select-Object -Unique)
                Add-Line 'info' 'GW' ("菜单项 {0} 个：{1}" -f @($entry.menus).Count, (@($entry.menus) -join ', '))
            } else {
                $cnt = ([regex]::Matches($body, '(?i)ipv6')).Count
                $entry.ipv6StringCount = $cnt
                if ($cnt -eq 0) {
                    Add-Line 'bad' 'GW' ("{0} 里 ipv6 出现 0 次 —— 该固件没有 IPv6 模块，原厂无解" -f $path)
                    $entry.verdict = 'firmware-has-no-ipv6'
                } else {
                    Add-Line 'ok' 'GW' ("{0} 里 ipv6 出现 {1} 次 —— 固件有 IPv6 相关界面" -f $path, $cnt)
                    $entry.verdict = 'firmware-has-ipv6'
                }
            }
        }
        $routerInfo += [pscustomobject]$entry
    }
    $script:result.router = $routerInfo
}

# ---------------------------------------------------------------- 结论
Section "结论"
$verdict = ''
$advice  = ''
if (-not $l0) {
    $verdict = 'L0-协议栈被禁用'
    $advice  = '先解开 DisabledComponents（管理员运行 ipv6-doctor-fix.ps1），再重测'
} elseif (-not $l1) {
    $verdict = 'L1-本机网卡没开 IPv6'
    $advice  = '这是最常见的假阴性。管理员运行 ipv6-doctor-fix.ps1 给网卡绑上 ms_tcpip6，再重测'
} elseif ($l3 -and $l4) {
    $verdict = 'OK-这条链路有可用的 IPv6'
    $advice  = '本机已能通过 IPv6 出网。要给多台设备分发，路由器需支持 NDP 中继或 NAPT66'
} elseif ($l3 -and -not $l4) {
    $verdict = 'L4-有地址但出不去'
    $advice  = '检查认证网关/防火墙；也可能是只有部分出口开了 v6'
} else {
    $verdict = 'L2-这条链路没有 IPv6'
    $advice  = '本机没问题，是上游没给 RA。换有线口 / 换网段 / 换 SSID 再测，刷路由器固件不会有帮助'
}
Add-Line 'info' '=>' ("判定：" + $verdict)
Add-Line 'info' '=>' ("建议：" + $advice)

$script:result.verdict = $verdict
$script:result.advice  = $advice
$script:result.checks  = $script:lines

if ($Json) {
    $script:result | ConvertTo-Json -Depth 8
} else {
    Write-Host ""
    Write-Host ("-" * 62)
    Write-Host ("  判定：" + $verdict) -ForegroundColor Cyan
    Write-Host ("  建议：" + $advice)  -ForegroundColor Cyan
    Write-Host ("-" * 62)
}

switch ($verdict) {
    'OK-这条链路有可用的 IPv6'      { exit 0 }
    'L4-有地址但出不去'             { exit 3 }
    'L2-这条链路没有 IPv6'          { exit 2 }
    default                        { exit 1 }
}
