# 实测案例：四川大学 江安校区 西园八舍

2026-11 实测。地理与运营商信息仅供定位，重点是**数据形态**。

## 结论

| 项目 | 值 |
|---|---|
| 接入点 | 宿舍墙上网口（有线，1 Gbps 链路） |
| 认证 | **免认证**，插上直接拿公网地址 |
| IPv4 | `121.48.199.149/24`，网关 `121.48.199.254`（CERNET 教育网公网段） |
| IPv6 前缀 | **`2001:250:2003:8f9f::/64`** |
| IPv6 地址来源 | `RouterAdvertisement`（SLAAC） |
| IPv6 默认路由 | `::/0 via fe80::7608:aaff:fe99:5c16` |
| 地址有效期 | Public 29 天 / Temporary 6 天 |
| ICMP 出口 | `2400:3200::1`、`240c::6666` 均通 |
| HTTP 出口 | `https://ipv6.baidu.com/` 通 |
| 谷歌 IPv6 | 不通（CERNET 2019-10 起屏蔽） |
| 前缀委派（PD） | **未观察到**（RA 直发 /64；Windows 不做 PD 客户端，无法进一步验证） |

## 踩的两个坑

### 坑 1：以太网网卡的 IPv6 绑定是关的

同一根网线、同一台机器：

```
Get-NetAdapterBinding -ComponentID ms_tcpip6
  以太网   False        ← 罪魁
  WLAN     True
```

而 `DisabledComponents = 0`，全局策略完全正常。表现：

- `netsh interface ipv6 show addresses` 里**没有"以太网"这个接口**
- `netsh interface ipv6 show route` 里没有 `::/0`
- 看起来就像"学校没给 IPv6"

打开绑定后立刻拿到地址。**这就是本项目的 L1 判定为什么必须存在。**

### 坑 2：无线和有线同时在线时走的是无线

同一台机器连着 `SCUNET`（校园无线）测，只有 `fe80::`，判断"没有 IPv6"。实际是流量全走无线，而那个 AP 确实没有 IPv6（另一个物理链路问题）。

测有线前必须 `netsh wlan disconnect`。

## 无线的对照数据

同一位置、同一台机器，连无线 `SCUNET`（5 GHz 802.11ax，需 web 认证）：

```
IPv4  10.134.61.147/21，网关 10.134.63.254     ← 内网段，有认证网关
IPv6  仅 fe80::，无 ::/0
ICMPv6 2400:3200::1 不通
```

**同一个人、同一间宿舍：有线口有 IPv6，无线 AP 没有。** 这说明"判断一个学校有没有 IPv6"必须精确到**具体哪个接入点**，不能按学校或楼栋下结论。

## 上游只有 SLAAC /64 没有 PD 的后果

RA 直接下发一整段 `/64`，没有 DHCPv6-PD。这意味着：

> 原厂家用路由器无法把 IPv6 分给局域网设备。

实测一台水星 MW325R（原厂固件）接在这个口上：

```
str.js（31837 字节界面文案）里 ipv6 出现 0 次
menu.js 完整菜单树 24 项，无任何 IPv6 入口
LAN 侧 ping -6 fe80::1 / fe80::2 均无回应，无 RA
```

即**连路由器自身都没有 IPv6 代码**，不是"配错了"。

⚠️ 顺带更正一个常见误解：这台机器的 WiFi SSID 叫 `MERCURY_26A3`，而 `26A3` 是 **BSSID `4c:b7:e0:fc:26:a3` 的末四位**，不是型号。真实型号要从 `http://192.168.1.1/` 返回页面的 `<title>` 里读（这里是 `MW325R`）。

## 复现方法

```powershell
# 1. 插网线，关无线
netsh wlan disconnect

# 2. 体检
powershell -NoProfile -ExecutionPolicy Bypass -File windows\ipv6-doctor.ps1

# 3. 若是 L1 判定失败，修复后重测
windows\ipv6-doctor-fix.bat
```

## 欢迎补充

如果你在别的学校测出结果，提 PR 加一个 `docs/case-<学校>.md`，至少包含：

- 接入方式（有线/无线、是否认证）
- IPv4 段属于内网还是公网教育网段
- IPv6 前缀、来源（RA / DHCPv6 / 手工）
- 是否有 PD
- 出口测试结果（国内目标 / 境外目标）
