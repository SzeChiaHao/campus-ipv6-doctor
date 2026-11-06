# campus-ipv6-doctor

**一条命令判断你学校的校园网到底有没有 IPv6，以及卡在哪一层。**

不是为了"检查 IPv6 有没有开"，而是为了回答那个真正费时间的问题：

> 我在宿舍折腾了三个小时，到底是**上游没给**，还是**我本机没开**？

这个仓库来自一次真实的排障：一台笔记本插着校园网有线口，系统 IPv6 协议栈完好、策略未禁、驱动正常，**但网卡上的 IPv6 协议绑定是关的**（`ms_tcpip6 = False`）。所有 `fe80::` 地址都在，所有"看起来正常"的迹象都在，就是永远拿不到全局地址和默认路由。而在此之前，已经有人对着上游、对着路由器固件白折腾了一整天。

---

## 五层判定模型

脚本从下往上逐层判定，**任何一层 FAIL 都会让上面的层失去意义**：

| 层 | 判什么 | 常见故障表现 |
|---|---|---|
| **L0 协议栈** | Windows `DisabledComponents` / Linux `disable_ipv6` | 组策略或优化工具把 IPv6 全局关了 |
| **L1 网卡** | 每张网卡的 IPv6 协议是否绑定（`ms_tcpip6`） | **最常见的假阴性**：只有 `fe80::`，接口根本不在 IPv6 接口表里 |
| **L2 链路** | 是否收到 Router Advertisement → 表现为 `::/0` 默认路由 | 只有 `fe80::/64`，没有任何默认路由 |
| **L3 地址** | 是否拿到全局地址（`2000::/3`） | 有 RA 但前缀被过滤 |
| **L4 出口** | 是否真能出网（ICMP + 纯 IPv6 HTTP） | 有地址但被认证网关/防火墙拦住 |

脚本给出四种判定之一：

- `OK-这条链路有可用的 IPv6`
- `L4-有地址但出不去`
- `L2-这条链路没有 IPv6` ← 到这一步就别再刷路由器固件了，没意义
- `L1-本机网卡没开 IPv6` / `L0-协议栈被禁用` ← 先修本机

退出码：`0` 可用 / `1` 本机未开 / `2` 链路无 IPv6 / `3` 有地址但出不去。可以塞进 CI 或登录脚本。

---

## 用法

### Windows（只读，不需要管理员）

```powershell
# 双击运行
windows\ipv6-doctor.bat

# 或命令行
powershell -NoProfile -ExecutionPolicy Bypass -File windows\ipv6-doctor.ps1

# 顺便探测路由器后台固件有没有 IPv6 模块
powershell -NoProfile -ExecutionPolicy Bypass -File windows\ipv6-doctor.ps1 -Router -ProbeHost 192.168.1.1

# 机器可读
powershell -NoProfile -ExecutionPolicy Bypass -File windows\ipv6-doctor.ps1 -Json
```

### 修复（需要管理员，会改设置）

```powershell
windows\ipv6-doctor-fix.bat
```

做三件事，全部可逆：

1. `DisabledComponents` 归零
2. 给**所有**网卡（含未连接的）绑定 `ms_tcpip6`
3. 清掉 Teredo / 6to4 / ISATAP 残留隧道，等 15 秒让网卡重发 RS

改之前会把 `netsh interface ipv6 show interface` 和 `show addresses` 存到桌面，方便对照和回退。

### Linux / macOS

```bash
chmod +x linux/ipv6-doctor.sh
./linux/ipv6-doctor.sh
```

只读。同样输出五层判定和退出码。

---

## 真实输出示例

川大江安校区宿舍有线口，修好 L1 之后：

```
=== L0 协议栈层：Windows 有没有全局禁用 IPv6 ===
 [ OK ] L0  DisabledComponents = 0，IPv6 协议栈未被全局禁用

=== L1 网卡层：每张网卡的 IPv6 协议有没有绑定 ===
 [ OK ] L1  以太网（ifIndex 10，1 Gbps）IPv6 已绑定

=== L2 链路层：有没有收到路由器通告（RA） ===
 [ OK ] L2  有 IPv6 默认路由：::/0 via fe80::7608:aaff:fe99:5c16（ifIndex 10）

=== L3 地址层：有没有全局 IPv6 地址 ===
 [ OK ] L3  2001:250:2003:8f9f:d7e6:bfa:a3c:6d29/64（ifIndex 10，来源 RouterAdvertisement）
 [ OK ] L3  2001:250:2003:8f9f:4c7f:9ab0:cf29:9d3b/128（ifIndex 10，来源 RouterAdvertisement）

=== L4 出口层：能不能真的出网 ===
 [ OK ] L4  AliDNS 2400:3200::1（国内） -> 通
 [ OK ] L4  联通DNS 240c::6666（国内） -> 通
 [ OK ] L4  https://ipv6.baidu.com/（纯 IPv6 域名）HTTP 通

  判定：OK-这条链路有可用的 IPv6
```

修之前，同一台机器、同一根网线：

```
=== L1 网卡层 ===
 [FAIL] L1  以太网（ifIndex 10）IPv6 未绑定 —— 这张卡压根不跑 IPv6，测什么都测不到

=== L2 链路层 ===
 [FAIL] L2  没有 ::/0 默认路由 —— 这条链路上从来没收到过路由器通告

  判定：L1-本机网卡没开 IPv6
```

**同样的网线、同样的机器，一次判定是"上游没有"，一次判定是"本机没开"。差的就是这两张表。**

---

## 常见误判（这些坑都踩过）

1. **只有 `fe80::` 不代表"没有 IPv6"**，但**没有 `::/0` 默认路由**一定代表"没收到 RA"。
2. **接口不在 `netsh int ipv6 show interface` 列表里** = 那张网卡的 IPv6 绑定是关的，看地址表永远看不出问题。
3. **同时插网线和连 Wi-Fi**，Windows 按接口跃点数自己挑路，很可能继续走 Wi-Fi。测有线前必须 `netsh wlan disconnect`。
4. **网卡是 `Not Present` / `Disconnected` 时不能跳过**，绑定状态照样要检查。
5. **PowerShell 5.1 读 `.ps1` 默认按 ANSI**，脚本里写中文必须存成 **UTF-8 with BOM**，否则解析直接崩。这个仓库的 `.ps1` 都是带 BOM 的。
6. **单元素 PSCustomObject 的 `.Count` 在 PS 5.1 返回 `$null`**，不是 1。判空一律用 `@($x).Count`。
7. **国内教育网普遍屏蔽谷歌 IPv6**（CERNET 2019 年 10 月起），所以 `ipv6.google.com` 不通**不能**作为"没有 IPv6"的证据。脚本只把国内目标计入判定。

更多：见 [`docs/gotchas.md`](docs/gotchas.md)。

---

## 路由器侧：原厂固件到底支不支持 IPv6

用 `-Router` 参数可以顺手查。对 **TP-Link / 水星(Mercury) / 迅捷(FAST)** 这一族 `dynaform` 固件有效：

```bash
curl -s http://192.168.1.1/language/cn/str.js | grep -oic ipv6
curl -s http://192.168.1.1/dynaform/menu.js
```

- `str.js` 是**全部界面文案**。`ipv6` 出现 **0 次** = 这个固件**连 IPv6 模块都没有**，后台里当然翻不到 IPv6 菜单，刷第三方固件是唯一解。
- `menu.js` 是**完整菜单树**，可以直接看出它有哪些功能页。

实测：水星 MW325R，`str.js` 31837 字节，`ipv6` 出现 0 次 —— 后台根本没有 IPv6 任何入口。

---

## 上游只给 SLAAC /64、没有前缀委派（PD）怎么办

这是国内校园网的常态：RA 直接下发一整段 `/64`，没有 DHCPv6-PD。后果是：

> **家用电器的原厂固件没法把 IPv6 分给局域网设备。**

因为原厂固件的"IPv6 前缀分配"依赖 PD。要在这种上游下把 IPv6 分给多台设备，只有两条路：

1. **NDP 中继（relay / proxy）**：把上级的 RA 转发到 LAN，并对 WAN 侧做 NDP 代理，让上级只看到路由器一个 MAC/地址。
2. **NAPT66 / NPTv6**：LAN 用内网 ULA 前缀（`fd00::/8`），出口统一用路由器 WAN 的地址。代价是丢失 IPv6 端到端能力（PT、入站连接受影响）。

支持这两条的固件：**OpenWrt（`odhcpd` relay / `relayd`）、padavan（内建 napt66 与 6relayd）**。原厂固件基本都不支持。

> `6relayd` 上游 2015 年就停更了，被 OpenWrt 的 `odhcpd` relay 模式取代；padavan 里还能用，但长时间无流量会掉线，需要定时 ping 保活。

---

## 已实测案例

- [`docs/case-scu.md`](docs/case-scu.md) —— 四川大学江安校区宿舍有线口：`2001:250:2003::/64`，SLAAC，免认证直连教育网公网段。

欢迎提 PR 补充你学校的实测结果（学校 / 网段 / 是否需要认证 / 前缀长度 / 是否给 PD）。

---

## License

MIT
