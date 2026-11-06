<#
.SYNOPSIS
  campus-ipv6-doctor 修复脚本 —— 把本机 IPv6 恢复到可用状态。

.DESCRIPTION
  只做 L0 / L1 / 隧道残留 这三件事，不碰任何手动配置：

    1) DisabledComponents 归零（L0）
    2) 给所有网卡（含 Disconnected / Not Present）绑定 ms_tcpip6（L1）
    3) 关闭 Teredo / 6to4 / ISATAP 残留隧道

  改之前会把当前 IPv6 接口表和地址表存到桌面，方便对照与回退。

.NOTES
  需要管理员权限。脚本会自己提权。
#>

[CmdletBinding()]
param(
    [switch]$NoBackup,
    [switch]$Reset                       # 额外执行 netsh int ipv6 reset（会要求重启）
)

$ErrorActionPreference = 'Continue'

# ---------- 自提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] 需要管理员权限，正在提权..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'))
    if ($NoBackup) { $argList += '-NoBackup' }
    if ($Reset)    { $argList += '-Reset' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Step($n, $t) {
    Write-Host ""
    Write-Host ("[" + $n + "] " + $t) -ForegroundColor Cyan
}

# ---------- 备份 ----------
if (-not $NoBackup) {
    Step '0/4' '备份当前 IPv6 状态到桌面'
    $desk = [Environment]::GetFolderPath('Desktop')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    try {
        netsh interface ipv6 show interface  | Out-File (Join-Path $desk "ipv6-if-$stamp.txt")  -Encoding UTF8
        netsh interface ipv6 show addresses  | Out-File (Join-Path $desk "ipv6-addr-$stamp.txt") -Encoding UTF8
        netsh interface ipv6 show route      | Out-File (Join-Path $desk "ipv6-route-$stamp.txt") -Encoding UTF8
        Write-Host ("    已保存 ipv6-if / ipv6-addr / ipv6-route ($stamp).txt") -ForegroundColor DarkGray
    } catch {
        Write-Host "    备份失败，但继续" -ForegroundColor Yellow
    }
}

# ---------- L0 ----------
Step '1/4' 'L0：DisabledComponents 归零'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$old = (Get-ItemProperty -Path $key -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents
try {
    Set-ItemProperty -Path $key -Name DisabledComponents -Value 0 -Type DWord -ErrorAction Stop
    if ($null -ne $old -and $old -ne 0) {
        Write-Host ("    原来是 0x{0:X}，已改为 0" -f $old) -ForegroundColor Green
    } else {
        Write-Host "    已是 0，无需改动" -ForegroundColor DarkGray
    }
} catch {
    Write-Host ("    写入失败: " + $_.Exception.Message) -ForegroundColor Red
}

# ---------- L1 ----------
Step '2/4' 'L1：给所有网卡绑定 ms_tcpip6'
$adapters = Get-NetAdapter
foreach ($a in $adapters) {
    try {
        $b = Get-NetAdapterBinding -Name $a.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
        if ($b.Enabled) {
            Write-Host ("    [已开] " + $a.Name) -ForegroundColor DarkGray
        } else {
            Enable-NetAdapterBinding -Name $a.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
            Write-Host ("    [已开启] " + $a.Name + "（" + $a.Status + "）") -ForegroundColor Green
        }
    } catch {
        Write-Host ("    [跳过] " + $a.Name + " : " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ---------- 隧道残留 ----------
Step '3/4' '清掉 Teredo / 6to4 / ISATAP 残留隧道'
netsh interface teredo set state disabled  | Out-Null
netsh interface 6to4   set state disabled  | Out-Null
netsh interface isatap set state disabled  | Out-Null
Write-Host "    已关闭三种过渡隧道（现代校园网用原生双栈，不需要它们）" -ForegroundColor DarkGray

if ($Reset) {
    Write-Host ""
    Write-Host "    执行 netsh interface ipv6 reset（需要重启才完全生效）" -ForegroundColor Yellow
    netsh interface ipv6 reset | Out-Null
}

# ---------- 等 RS ----------
Step '4/4' '等 15 秒，让网卡重发路由器请求（RS）'
Start-Sleep -Seconds 15

Write-Host ""
Write-Host ("-" * 62) -ForegroundColor DarkGray
Write-Host "现在的状态：" -ForegroundColor Cyan
netsh interface ipv6 show addresses | Select-String -Pattern '接口|Interface|2001:|2408:|2409:|240e:|fe80' | ForEach-Object { $_.Line }
Write-Host ""
$dr = Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
if ($dr) {
    foreach ($r in $dr) { Write-Host ("  默认路由 ::/0 via " + $r.NextHop + "（ifIndex " + $r.ifIndex + "）") -ForegroundColor Green }
} else {
    Write-Host "  没有 ::/0 默认路由 —— 上游没发 RA，本机怎么改都不会有用" -ForegroundColor Yellow
}
Write-Host ("-" * 62) -ForegroundColor DarkGray
Write-Host ""
Write-Host "接着跑 ipv6-doctor.ps1 看完整判定。" -ForegroundColor Cyan
