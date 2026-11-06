# 踩坑清单

每一条都来自实际排障，不是猜的。

## 1. `fe80::` 不代表没有 IPv6，但没有 `::/0` 一定代表没有

链路本地地址是 IPv6 协议的必需品：只要网卡绑定了 IPv6 协议，哪怕整个网络一个 RA 都收不到，系统也会自动生成一个 `fe80::xxxx` 地址。

所以"我 ping 不到 IPv6"和"我只有 fe80 地址"都不能下结论。真正的判据是**默认路由表里有没有 `::/0`**：

```
netsh interface ipv6 show route
# Linux: ip -6 route show default
```

有 `::/0` = 收到过 RA；没有 = 这条链路上没有任何路由器宣告过 IPv6。

## 2. 网卡的 IPv6 绑定可能是关的，而地址表看不出来

Windows 上 IPv6 有两个开关：

1. 全局策略 `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\DisabledComponents`
2. **每张网卡**的 `ms_tcpip6` 绑定（就是"Internet 协议版本 6 (TCP/IPv6)"那个勾）

两者独立。第 2 个关掉时：

- `DisabledComponents = 0`（看起来"IPv6 是开的"）
- 该网卡还会有一个 `fe80::` 地址（迷惑性极强）
- 但 `netsh interface ipv6 show interface` 里**根本没有这张网卡的索引**

检查：

```powershell
Get-NetAdapterBinding -ComponentID ms_tcpip6
```

`Enabled = False` 的网卡，插在这张卡上的任何测试都没有意义。

**这是本项目诞生的原因。**

## 3. 同时连 Wi-Fi 和插网线时，Windows 会自己挑路

Windows 按"接口跃点数（interface metric）"决定默认路由优先级，无线通常比有线低。结果是：你插了网线，但流量还走 Wi-Fi。

测有线前：

```
netsh wlan disconnect
```

或在界面里关掉 Wi-Fi。测完再连回来。

判据：体检报告里"当前无线"那一栏应该是空的。

## 4. `Not Present` / `Disconnected` 的网卡也要检查

修复脚本必须处理**全部**网卡，不能只处理 `Status -eq 'Up'` 的。否则网线拔着的时候跑修复，等插上网线照样是关的。

## 5. PowerShell 5.1 读 `.ps1` 默认按 ANSI 编码

Windows 自带的 PowerShell 5.1 在解析 `.ps1` 时，如果文件没有 BOM，会按系统 ANSI 代码页（简中是 GBK）解释。脚本里只要有中文全角标点，就可能出现：

```
字符串缺少终止符
表达式或语句中包含意外的标记
```

**解决：`.ps1` 一律存成 UTF-8 with BOM。**

```python
open(path, 'w', encoding='utf-8-sig').write(src)
```

PowerShell 7 默认按 UTF-8 读，不受影响，但为了兼容 5.1 建议统一带 BOM。

## 6. 单元素 PSCustomObject 的 `.Count` 返回 `$null`

PowerShell 里 `@(1,2).Count` 是 2。但如果你用 `Where-Object` 过滤到只剩一个 `PSCustomObject`，`.Count` 在 5.1 下返回 `$null` 而不是 1：

```powershell
$up = $rows | Where-Object { $_.status -eq 'Up' }
$up.Count        # -> $null（只有一个元素时）
@($up).Count     # -> 1   ✓
```

于是 `if ($up.Count -gt 0)` 永远为假。本项目在这个坑上翻过一次车，判定逻辑整个反了。

**规则：凡是对可能单元素的集合取计数，一律 `@($x).Count`。**

## 7. 国内教育网屏蔽谷歌 IPv6，不能拿它当判据

CERNET 自 2019 年 10 月起屏蔽了谷歌全系 IPv6 地址（当年"教育网 IPv6 直连谷歌"的红利已经消失）。

所以：

- `ping -6 ipv6.google.com` 不通 **不等于** 你没有 IPv6
- 判定必须用国内可达目标（AliDNS `2400:3200::1`、联通 `240c::6666`、`ipv6.baidu.com`）

本项目的境外目标只作为参考信息输出，不计入判定。

## 8. 上游只给 `/64`、没有 PD 时，原厂固件"前缀分配"是空的

校园网常见配置：RA 直接下发一整段 `/64`（SLAAC），不发 DHCPv6-PD。

家用电器的"IPv6 前缀分配"功能依赖 PD，没有 PD 就分不出东西。要在这种情况下给局域网设备发 IPv6，只能：

- NDP 中继（relay / proxy）
- NAPT66 / NPTv6

原厂固件基本都没有。这就是"为什么必须刷 OpenWrt/padavan"的真正原因，跟"原厂不好用"这种模糊说法无关。

## 9. 判断原厂固件有没有 IPv6：直接扒它的界面文案

TP-Link / 水星(Mercury) / 迅捷(FAST) 这一族的 `dynaform` 固件，界面文案全在：

```
http://<路由器IP>/language/cn/str.js
http://<路由器IP>/dynaform/menu.js
```

这两个文件**通常不需要登录就能访问**（它们是登录页的依赖资源）。

```bash
curl -s http://192.168.1.1/language/cn/str.js | grep -oic ipv6
```

- 结果是 `0` → 固件里连 IPv6 这个字符串都没有，后台翻不到是正常的，别再找了
- `menu.js` 则直接给出完整菜单树，等于把"这台机器有哪些功能页"全招了

实测：水星 MW325R，`str.js` 31837 字节，`ipv6` 出现 **0 次**。

## 10. 出口 IP 能区分"内网认证网"和"公网教育网口"

```
curl -s https://ipinfo.io/ip
```

- `10.x` / `172.16-31.x` / `192.168.x` → 内网段，后面还有认证网关（锐捷/Dr.COM 之类）
- `121.48.x` / `202.115.x` / `202.112.x` 等 CERNET 公网段 → 直接在教育网上，通常免认证

这一步能省掉大量猜测：如果是公网段，就不必再折腾认证页面。

## 11. 有地址但 ping 不通 ≠ 本机故障

有些学校的出口对 IPv6 做了 ICMP 过滤，或者只对认证后的会话放行。判据要用 TCP/HTTP（`https://ipv6.baidu.com/`），不要只信 `ping -6`。

## 12. 2019 年前后的大量教程已经失效

如果你翻到"用 ISATAP 隧道连教育网 IPv6"这类教程（典型标志是一行 `netsh int ipv6 isatap set router <某个 IP>` 的批处理）：

- 微软在 Windows 10 后期已不再维护 ISATAP 客户端
- 各校的 ISATAP 网关在 2019–2021 年间陆续下线
- 现在校园网基本都是原生双栈 + SLAAC，不需要隧道

跑完那种脚本后，ISATAP 接口会留下一个 `fe80::5efe:<IPv4>` 地址，看起来"有 IPv6 了"，其实什么都连不上。而且这类脚本常附带"确认原生 IPv6 已经关闭"的说明——把唯一能用的方案也关掉了。
