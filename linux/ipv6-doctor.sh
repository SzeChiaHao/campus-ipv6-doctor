#!/usr/bin/env bash
# campus-ipv6-doctor — Linux / macOS 体检
#
# 五层判定：L0 协议栈 / L1 网卡 / L2 链路(RA) / L3 地址 / L4 出口
# 只读，不修改任何系统设置。
#
# 用法: ./ipv6-doctor.sh [-j]
#   -j  输出 JSON
# 退出码: 0 可用 / 1 本机未开 / 2 链路无 IPv6 / 3 有地址但出不去

set -u

JSON=0
[ "${1:-}" = "-j" ] && JSON=1

OS="$(uname -s)"
TARGET_CN_1="2400:3200::1"          # AliDNS
TARGET_CN_2="240c::6666"            # 联通 DNS
TARGET_ABROAD="2001:4860:4860::8888" # Google DNS，仅参考

if [ -t 1 ] && [ "$JSON" = "0" ]; then
  c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_warn=$'\033[33m'
  c_info=$'\033[36m'; c_dim=$'\033[90m'; c_off=$'\033[0m'
else
  c_ok=""; c_bad=""; c_warn=""; c_info=""; c_dim=""; c_off=""
fi

JSON_ITEMS=()

say() { # say <level> <layer> <text>
  local level="$1" layer="$2" text="$3" tag color
  JSON_ITEMS+=("{\"level\":\"${level}\",\"layer\":\"${layer}\",\"text\":\"${text//\"/\\\"}\"}")
  [ "$JSON" = "1" ] && return
  case "$level" in
    ok)   tag="[ OK ]"; color="$c_ok" ;;
    bad)  tag="[FAIL]"; color="$c_bad" ;;
    warn) tag="[WARN]"; color="$c_warn" ;;
    *)    tag="[ .. ]"; color="$c_dim" ;;
  esac
  printf '%s%s%s %-3s %s\n' "$color" "$tag" "$c_off" "$layer" "$text"
}

section() {
  [ "$JSON" = "1" ] && return
  printf '\n%s=== %s ===%s\n' "$c_info" "$1" "$c_off"
}

have() { command -v "$1" >/dev/null 2>&1; }

ping6_any() { # ping6_any <addr> <count>
  if have ping; then
    ping -6 -c "$2" -W 2 "$1" >/dev/null 2>&1 && return 0
  fi
  if have ping6; then
    ping6 -c "$2" "$1" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ------------------------------------------------------------------ L0
section "L0 协议栈层：系统有没有禁用 IPv6"
l0=1
if [ "$OS" = "Linux" ]; then
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    d=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    if [ "$d" = "0" ]; then
      say ok L0 "net.ipv6.conf.all.disable_ipv6 = 0，协议栈未被禁用"
    else
      say bad L0 "net.ipv6.conf.all.disable_ipv6 = $d，IPv6 被内核禁用"
      say warn L0 "临时修复: sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0"
      l0=0
    fi
  else
    say bad L0 "内核没有 /proc/sys/net/ipv6（IPv6 模块未加载，试 modprobe ipv6）"
    l0=0
  fi
else
  if ifconfig 2>/dev/null | grep -q 'inet6'; then
    say ok L0 "系统上有 inet6 地址，协议栈在工作"
  else
    say warn L0 "没看到任何 inet6 地址（也可能只是这个网络没有 RA）"
  fi
fi

# ------------------------------------------------------------------ L1 / L3
section "L1 网卡层：网卡有没有跑 IPv6"
l1=1
IFACES=()
if [ "$OS" = "Linux" ] && have ip; then
  while IFS= read -r ifname; do
    [ -z "$ifname" ] && continue
    [ "$ifname" = "lo" ] && continue
    IFACES+=("$ifname")
    state=$(ip -o link show "$ifname" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
    [ "$state" = "UP" ] || continue
    f="/proc/sys/net/ipv6/conf/$ifname/disable_ipv6"
    if [ -r "$f" ] && [ "$(cat "$f")" = "1" ]; then
      say bad L1 "$ifname 的 disable_ipv6 = 1，这张卡不跑 IPv6"
      l1=0
    else
      say ok L1 "$ifname 已启用 IPv6"
    fi
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')
fi

section "L3 地址层：有没有全局 IPv6 地址"
l3=0
ULA_ONLY=1
if [ "$OS" = "Linux" ] && have ip; then
  while IFS=' ' read -r cidr ifname; do
    [ -z "$cidr" ] && continue
    case "$cidr" in
      fe80::*|::1/128) continue ;;
    esac
    say ok L3 "${cidr}（${ifname}）"
    case "$cidr" in
      fd*|fc*) ;;                 # ULA，不算公网可达
      *) l3=1; ULA_ONLY=0 ;;
    esac
  done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4, $2}')
else
  while IFS=' ' read -r cidr ifname; do
    [ -z "$cidr" ] && continue
    case "$cidr" in
      fe80::*) continue ;;
    esac
    say ok L3 "${cidr}（${ifname}）"
    case "$cidr" in
      fd*|fc*) ;;
      *) l3=1; ULA_ONLY=0 ;;
    esac
  done < <(ifconfig 2>/dev/null | awk '/^[a-zA-Z0-9]+:/{ifc=$1; sub(":","",ifc)} /inet6 /{if ($2 !~ /^fe80/) print $2, ifc}')
fi

if [ "$l3" = "0" ] && [ "$ULA_ONLY" = "1" ] && [ "${#JSON_ITEMS[@]}" -gt 0 ]; then
  : # 只拿到 ULA 也不等于能出网，下面 L2/L4 会给结论
fi
if ! printf '%s' "${JSON_ITEMS[*]}" | grep -q '"layer":"L3"'; then
  say bad L3 "没有全局 IPv6 地址（只有 fe80:: 链路本地）"
fi

# ------------------------------------------------------------------ L2
section "L2 链路层：有没有收到路由器通告（RA）"
l2=0
DEF_ROUTE=""
if [ "$OS" = "Linux" ] && have ip; then
  DEF_ROUTE=$(ip -6 route show default 2>/dev/null | head -1)
else
  DEF_ROUTE=$(netstat -rn 2>/dev/null | awk '($1=="default"||$1=="::/0") && $2 ~ /:/ {print; exit}')
fi
if [ -n "$DEF_ROUTE" ]; then
  say ok L2 "有 IPv6 默认路由: $DEF_ROUTE"
  l2=1
else
  say bad L2 "没有 IPv6 默认路由 —— 这条链路上从来没收到过路由器通告"
  say info L2 "只有 fe80:: 地址不代表没有 IPv6；没有默认路由才是真的没收到 RA"
fi

if have ip && [ -n "$DEF_ROUTE" ]; then
  dev=$(echo "$DEF_ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  [ -z "$dev" ] && dev=$(echo "$DEF_ROUTE" | awk '{print $NF}')
  nb=$(ip -6 neigh show dev "$dev" 2>/dev/null | grep -c lladdr || true)
  [ "${nb:-0}" -gt 0 ] 2>/dev/null && say info L2 "邻居表里有 $nb 条 IPv6 邻居（旁证，不是判据）"
fi

# 无线
SSID=""
if have nmcli; then
  SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
elif have iwgetid; then
  SSID=$(iwgetid -r 2>/dev/null)
elif [ "$OS" = "Darwin" ] && have networksetup; then
  SSID=$(networksetup -getairportnetwork en0 2>/dev/null | sed 's/^.*: //')
fi
if [ -n "$SSID" ]; then
  say info WIFI "当前无线: $SSID"
  say info WIFI "测有线时先断开无线，否则系统可能仍然走无线"
else
  say info WIFI "当前未连接无线"
fi

# ------------------------------------------------------------------ L4
section "L4 出口层：能不能真的出网"
l4=0
if [ "$l3" = "1" ]; then
  if ping6_any "$TARGET_CN_1" 2; then
    say ok L4 "$TARGET_CN_1（AliDNS） -> 通"; l4=1
  else
    say bad L4 "$TARGET_CN_1（AliDNS） -> 不通"
  fi
  if ping6_any "$TARGET_CN_2" 2; then
    say ok L4 "$TARGET_CN_2（联通DNS） -> 通"; l4=1
  else
    say bad L4 "$TARGET_CN_2（联通DNS） -> 不通"
  fi
  if ping6_any "$TARGET_ABROAD" 1; then
    say info L4 "$TARGET_ABROAD（境外，参考项） -> 通"
  else
    say info L4 "$TARGET_ABROAD（境外，参考项） -> 不通（国内教育网普遍屏蔽，不算故障）"
  fi
  if have curl; then
    code=$(curl -6 -sS --max-time 10 -o /dev/null -w '%{http_code}' https://ipv6.baidu.com/ 2>/dev/null || true)
    if [ "${code:-000}" != "000" ]; then
      say ok L4 "https://ipv6.baidu.com/ HTTP $code"; l4=1
    else
      say warn L4 "https://ipv6.baidu.com/ 不通（可能被认证网关或防火墙拦截）"
    fi
  fi
else
  say info L4 "没有全局地址，跳过出口测试"
fi

# ------------------------------------------------------------------ 结论
if [ "$l0" = "0" ]; then
  VERDICT="L0-协议栈被禁用"
  ADVICE="先解开 disable_ipv6（sysctl 或 GRUB 参数），再重测"
elif [ "$l1" = "0" ]; then
  VERDICT="L1-本机网卡没开 IPv6"
  ADVICE="解开对应网卡的 disable_ipv6，再重测"
elif [ "$l3" = "1" ] && [ "$l4" = "1" ]; then
  VERDICT="OK-这条链路有可用的 IPv6"
  ADVICE="本机已能通过 IPv6 出网。要给多台设备分发，路由器需支持 NDP 中继或 NAPT66"
elif [ "$l3" = "1" ]; then
  VERDICT="L4-有地址但出不去"
  ADVICE="检查认证网关/防火墙；也可能只有部分出口开了 v6"
else
  VERDICT="L2-这条链路没有 IPv6"
  ADVICE="本机没问题，是上游没给 RA。换有线口/换网段/换 SSID 再测，刷路由器固件不会有帮助"
fi

if [ "$JSON" = "1" ]; then
  joined=$(IFS=,; echo "${JSON_ITEMS[*]}")
  printf '{"os":"%s","verdict":"%s","advice":"%s","checks":[%s]}\n' \
    "$OS" "$VERDICT" "$ADVICE" "$joined"
else
  printf '\n%s\n' "------------------------------------------------------------"
  printf '  %s判定：%s%s\n' "$c_info" "$VERDICT" "$c_off"
  printf '  %s建议：%s%s\n' "$c_info" "$ADVICE"  "$c_off"
  printf '%s\n' "------------------------------------------------------------"
fi

case "$VERDICT" in
  "OK-这条链路有可用的 IPv6") exit 0 ;;
  "L4-有地址但出不去")        exit 3 ;;
  "L2-这条链路没有 IPv6")     exit 2 ;;
  *)                          exit 1 ;;
esac
