#!/usr/bin/env bash
set -euo pipefail

VERSION="2026.05.25.6"
MIB=1048576
AUTO_TCP_CAP=$((2047 * MIB))

# 术语备注：
# BBR/BBR3：Linux TCP 拥塞控制算法名，保留英文。
# TFO/TCP Fast Open：TCP 快速打开，减少本机主动连接或本机监听服务的握手等待。
# RPS/RSS：网卡/内核收包分流机制，保留英文缩写。
# nftables/conntrack/sysctl/systemd：Linux 内核转发、防火墙状态跟踪、内核参数和服务管理组件名。
# fq/fq_codel/qdisc：Linux 队列调度器名，保留英文。
# busy_poll/busy_read：Linux 低延迟轮询参数名，保留英文。
# initcwnd/initrwnd/txqueuelen/nofile：路由初始窗口、网卡发送队列和文件描述符限制参数名。

ROLE=""
SCENE=""
TARGET="speed"
BUSINESS="mixed"
STATEFUL="yes"
LANDING_ROUTES="no"
IPV6_RA="ask"
MULTIPATH="yes"
HANDSHAKE="yes"
TFO_GLOBAL="no"
LOCAL_TCP_TERMINATION="auto"
BUSY_MODE="auto"
APPLY_MODE="ask"
UI_MODE="menu"
OUT_DIR=""
OUT_DIR_AUTO="no"
CLEAN_OUTPUTS="no"
DRAFT_DIRTY="no"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold || true)
  DIM=$(tput dim || true)
  GREEN=$(tput setaf 2 || true)
  CYAN=$(tput setaf 6 || true)
  RESET=$(tput sgr0 || true)
else
  BOLD=""
  DIM=""
  GREEN=""
  CYAN=""
  RESET=""
fi

TTY_DEVICE="/dev/tty"

restore_terminal() {
  tput cnorm 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap restore_terminal EXIT
trap 'restore_terminal; exit 130' INT TERM

has_tty() {
  [[ -r "$TTY_DEVICE" && -w "$TTY_DEVICE" ]]
}

prompt_read() {
  local __var="$1" prompt="$2"
  if has_tty; then
    printf '%s' "$prompt" > "$TTY_DEVICE"
    IFS= read -r "${__var?}" < "$TTY_DEVICE"
  else
    IFS= read -r -p "$prompt" "${__var?}"
  fi
}

read_key() {
  local __var="$1" pressed rest
  local input="$TTY_DEVICE"
  has_tty || input="/dev/stdin"
  IFS= read -rsn1 pressed < "$input" || return 1
  if [[ "$pressed" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.2 rest < "$input" || rest=""
    pressed+="$rest"
  fi
  printf -v "$__var" '%s' "$pressed"
}

choice_label() {
  case "$1" in
    yes) printf '是 - 开启/确认' ;;
    no) printf '否 - 关闭/不启用' ;;
    forwarding) printf '转发节点 - nftables/路由内核转发机器' ;;
    landing) printf '落地节点 - 3x-ui/Xray 等应用层出口机器' ;;
    front) printf '前置入口 - 家里路由器或用户先进入的第一跳转发' ;;
    ix) printf 'IX 专线 - 专线/IX 汇聚跳，只做极致内核转发' ;;
    relay) printf '线路中继 - 跨境或长 RTT 线路转发' ;;
    international) printf '国际互联 - 公网国际段/不可控跨境转发' ;;
    plain) printf '普通 nftables 转发 - 通用内核转发画像' ;;
    speed) printf '极致满速 - 新连接和测速尽快跑满，同时控制队列' ;;
    throughput) printf '极致吞吐 - 更偏大流量长时间持续吞吐' ;;
    mixed) printf 'TCP+UDP 双优化 - 默认同时照顾 TCP 满速和 UDP 会话' ;;
    tcp) printf 'TCP 长连接 - 长连接、代理隧道或大流量 TCP' ;;
    udp_game) printf 'UDP 游戏/实时 - 游戏、语音、实时 UDP' ;;
    web) printf 'Web/HTTPS - 网站、API、短连接 HTTPS' ;;
    auto) printf '自动 - 按带宽/RTT/业务自动判断' ;;
    force) printf '强制开启 - 跳过自动判断直接启用' ;;
    off) printf '关闭 - 不启用该项' ;;
    bbr1) printf 'BBR1 - 按常见 BBR1 内核计算' ;;
    bbr3) printf 'BBR3 - 仅在确认内核是 BBR3 时选择' ;;
    unknown) printf '未知 - 不确定版本时使用，按 BBR1/未知保守计算' ;;
    *) printf '%s' "$1" ;;
  esac
}

choice_short_label() {
  case "$1" in
    yes|no) yn_label "$1" ;;
    auto) printf '自动' ;;
    force) printf '强制开启' ;;
    off) printf '关闭' ;;
    bbr1) printf 'BBR1' ;;
    bbr3) printf 'BBR3' ;;
    unknown) printf '未知' ;;
    *) printf '%s' "$1" ;;
  esac
}

select_option() {
  local prompt="$1" default="$2" key count cursor=0 i
  shift 2
  local options=("$@")
  count="${#options[@]}"
  (( count > 0 )) || return 1
  for ((i=0; i<count; i++)); do
    if [[ "${options[$i]}" == "$default" ]]; then
      cursor="$i"
      break
    fi
  done

  while true; do
    printf '\033[H\033[2J' > "$TTY_DEVICE"
    printf '%s%s%s\n' "$BOLD" "$prompt" "$RESET" > "$TTY_DEVICE"
    printf '%s↑/↓ 或 j/k 选择，Enter 确认，q 返回/退出%s\n\n' "$DIM" "$RESET" > "$TTY_DEVICE"
    for ((i=0; i<count; i++)); do
      if (( i == cursor )); then
        printf '  %s> %s%s\n' "$GREEN" "$(choice_label "${options[$i]}")" "$RESET" > "$TTY_DEVICE"
      else
        printf '    %s\n' "$(choice_label "${options[$i]}")" > "$TTY_DEVICE"
      fi
    done

    read_key key || return 1
    case "$key" in
      $'\e[A'|$'\eOA'|k|K) cursor=$(((cursor + count - 1) % count)) ;;
      $'\e[B'|$'\eOB'|j|J) cursor=$(((cursor + 1) % count)) ;;
      ""|$'\r'|$'\n') printf '%s' "${options[$cursor]}"; return 0 ;;
      q|Q) printf '%s' "$default"; return 0 ;;
      [1-9])
        if (( key >= 1 && key <= count )); then
          printf '%s' "${options[$((key - 1))]}"
          return 0
        fi
        ;;
    esac
  done
}

hr() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

pause_ui() {
  local _
  prompt_read _ "按 Enter 继续..." || true
}

clear_ui() {
  if [[ -t 1 ]]; then
    printf '\033[H\033[2J'
  fi
}

banner() {
  clear_ui
  printf '%s中文 BBR 网络优化器%s  %s%s%s\n' "$BOLD" "$RESET" "$CYAN" "$VERSION" "$RESET"
  printf '目标: 极致满速 + 可控低抖动 | 默认不启用应用层 mux\n'
  printf '术语: BBR/TFO/RPS/nftables/conntrack/sysctl 保留英文，选项内带中文备注\n'
  hr
}

yn_label() {
  [[ "${1:-no}" == "yes" ]] && printf '是' || printf '否'
}

role_label() {
  case "${ROLE:-forwarding}" in
    forwarding) printf '转发节点' ;;
    landing) printf '落地节点' ;;
    *) printf '%s' "$ROLE" ;;
  esac
}

scene_label() {
  case "${SCENE:-plain}" in
    front) printf '前置入口' ;;
    ix) printf 'IX 专线' ;;
    relay) printf '线路中继' ;;
    international) printf '国际互联' ;;
    plain) printf '普通 nftables 转发' ;;
    landing) printf '落地' ;;
    *) printf '%s' "$SCENE" ;;
  esac
}

target_label() {
  case "${TARGET:-speed}" in
    speed) printf '极致满速' ;;
    throughput) printf '极致吞吐' ;;
    *) printf '%s' "$TARGET" ;;
  esac
}

business_label() {
  case "${BUSINESS:-mixed}" in
    mixed) printf 'TCP+UDP 双优化' ;;
    tcp) printf 'TCP 长连接' ;;
    udp_game) printf 'UDP 游戏/实时' ;;
    web) printf 'Web/HTTPS' ;;
    *) printf '%s' "$BUSINESS" ;;
  esac
}

show_summary() {
  printf '%s待生效配置草案%s\n' "$BOLD" "$RESET"
  printf '  说明            : 这里是你修改后的待生成/待应用配置，不是当前系统已生效值。\n'
  printf '  角色/场景      : %s / %s\n' "$(role_label)" "$(scene_label)"
  printf '  目标/业务      : %s / %s\n' "$(target_label)" "$(business_label)"
  printf '  带宽 Mbps      : 上行 %s / 下行 %s\n' "$UP_MBPS" "$DOWN_MBPS"
  printf '  RTT ms         : 上游 %s / 下游 %s\n' "$UP_RTT" "$DOWN_RTT"
  printf '  丢包/抖动      : %s%% / %sms\n' "$LOSS_PCT" "$JITTER_MS"
  printf '  网卡/队列      : %s / RX %s / TX %s / CPU %s\n' "$DEFAULT_IFACE" "$RX_QUEUES" "$TX_QUEUES" "$CPU_COUNT"
  printf '  转发状态       : 状态规则=%s, 落地路由=%s, 多出口/策略路由=%s, IPv6 RA=%s\n' \
    "$(yn_label "$STATEFUL")" "$(yn_label "$LANDING_ROUTES")" "$(yn_label "$MULTIPATH")" "$(yn_label "$IPV6_RA")"
  printf '  握手优化       : TFO=%s, 本机终止 TCP=%s, 全局监听 TFO=%s, busy_poll=%s\n' \
    "$(yn_label "$HANDSHAKE")" "$(yn_label "$LOCAL_TCP_TERMINATION")" "$(yn_label "$TFO_GLOBAL")" "$(choice_short_label "$BUSY_MODE")"
  printf '  手动覆盖       : TCP上限=%sMB, BDP倍数=%s, TCP并发=%s, UDP会话=%s, CPS=%s\n' \
    "$MANUAL_TCP_CAP_MB" "$MANUAL_BDP_MULT" "$TCP_CONNS_OVERRIDE" "$UDP_SESSIONS_OVERRIDE" "$CPS_OVERRIDE"
  if [[ -n "$SERVICE_NAME" ]]; then
    printf '  服务 nofile    : %s\n' "$SERVICE_NAME"
  fi
  return 0
}

print_live_sysctl() {
  local key="$1" value
  if sysctl_exists "$key"; then
    value="$(read_sysctl "$key" "读取失败")"
    printf '  %-46s %s\n' "$key" "$value"
  else
    printf '  %-46s %s\n' "$key" "当前内核不存在"
  fi
}

show_live_status_body() {
  printf '%s系统已生效参数%s\n' "$BOLD" "$RESET"
  printf '  说明            : 以下为从当前系统实时读取的值；修改 1-5 项后，主界面会切换为待生效配置草案。\n'
  printf '  默认网卡        : %s / RX %s / TX %s / CPU %s\n\n' "$DEFAULT_IFACE" "$RX_QUEUES" "$TX_QUEUES" "$CPU_COUNT"
  print_live_sysctl net.ipv4.tcp_congestion_control
  print_live_sysctl net.core.default_qdisc
  print_live_sysctl net.ipv4.tcp_fastopen
  print_live_sysctl net.ipv4.tcp_rmem
  print_live_sysctl net.ipv4.tcp_wmem
  print_live_sysctl net.core.rmem_max
  print_live_sysctl net.core.wmem_max
  print_live_sysctl net.ipv4.tcp_limit_output_bytes
  print_live_sysctl net.core.netdev_max_backlog
  print_live_sysctl net.core.busy_poll
  print_live_sysctl net.ipv4.ip_forward
  print_live_sysctl net.ipv6.conf.all.forwarding
  print_live_sysctl net.ipv4.conf.all.rp_filter
  print_live_sysctl net.netfilter.nf_conntrack_max
  printf '\n'
  ip -br link show "$DEFAULT_IFACE" 2>/dev/null || true
  ip route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  printf '\n'
}

show_live_status() {
  banner
  show_live_status_body
  pause_ui
}

default_state_dir() {
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/network-bbr-optimizer' "$XDG_STATE_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.local/state/network-bbr-optimizer' "$HOME"
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf '/root/.local/state/network-bbr-optimizer'
  else
    printf '/tmp/network-bbr-optimizer'
  fi
}

clean_legacy_outputs() {
  local path answer count=0
  local -a outputs=()
  for path in "$PWD"/bbr-output-*; do
    [[ -d "$path" ]] || continue
    outputs+=("$path")
  done
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    for path in /root/network-optimize-backup-*; do
      [[ -d "$path" ]] || continue
      outputs+=("$path")
    done
  fi
  if (( ${#outputs[@]} == 0 )); then
    printf '没有发现旧版 bbr-output-* 或 /root/network-optimize-backup-* 目录。\n'
    [[ "$CLEAN_OUTPUTS" == "yes" ]] || pause_ui
    return 0
  fi

  printf '将删除这些旧版输出/备份目录：\n'
  printf '  %s\n' "${outputs[@]}"
  if has_tty || [[ -t 0 ]]; then
    answer=$(ask_yes_no "确认删除这些旧输出目录" "no")
    [[ "$answer" == "yes" ]] || { printf '已取消清理。\n'; [[ "$CLEAN_OUTPUTS" == "yes" ]] || pause_ui; return 0; }
  fi
  for path in "${outputs[@]}"; do
    [[ -n "$path" ]] || continue
    [[ "$(basename "$path")" == bbr-output-* || "$(basename "$path")" == network-optimize-backup-* ]] || continue
    rm -rf -- "$path"
    count=$((count + 1))
  done
  printf '已清理 %s 个旧输出/备份目录。新的输出和备份默认放在隐藏状态目录。\n' "$count"
  [[ "$CLEAN_OUTPUTS" == "yes" ]] || pause_ui
}

edit_role_scene() {
  banner
  printf '%s角色与场景%s\n' "$BOLD" "$RESET"
  ROLE=$(ask_choice "机器角色" "$ROLE" forwarding landing)
  if [[ "$ROLE" == "forwarding" ]]; then
    SCENE=$(ask_choice "转发场景" "${SCENE:-plain}" front ix relay international plain)
    STATEFUL=$(ask_yes_no "是否 NAT/TProxy/状态 nftables 规则" "$STATEFUL")
    LANDING_ROUTES="no"
    LOCAL_TCP_TERMINATION=$(ask_yes_no "这台转发机是否也终止 TCP，例如还有代理/Web 监听服务" "$LOCAL_TCP_TERMINATION")
  else
    SCENE="landing"
    LANDING_ROUTES=$(ask_yes_no "落地机是否同时做 NAT/路由" "$LANDING_ROUTES")
    [[ "$LANDING_ROUTES" == "yes" ]] && STATEFUL="yes" || STATEFUL="no"
    LOCAL_TCP_TERMINATION=$(ask_yes_no "落地机是否本机终止 TCP，例如 Xray/Web/代理监听服务" "$LOCAL_TCP_TERMINATION")
  fi
  TARGET=$(ask_choice "优化目标" "$TARGET" speed throughput)
  BUSINESS=$(ask_choice "业务类型" "$BUSINESS" mixed tcp udp_game web)
}

edit_link() {
  banner
  printf '%s链路参数%s\n' "$BOLD" "$RESET"
  UP_MBPS=$(to_int "$(ask "上行/入口 Mbps" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "下行/出口 Mbps" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "上游 RTT ms" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "下游 RTT ms" "$DOWN_RTT")")
  LOSS_PCT=$(ask "丢包率百分比，例如 0 或 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "抖动 ms" "$JITTER_MS")")
  MULTIPATH=$(ask_yes_no "是否多出口/策略路由/非对称回程" "$MULTIPATH")
  IPV6_RA=$(ask_yes_no "IPv6 默认路由是否依赖 RA" "$IPV6_RA")
}

edit_runtime() {
  banner
  printf '%s网卡与运行时%s\n' "$BOLD" "$RESET"
  CPU_COUNT=$(to_int "$(ask "CPU 核数" "$CPU_COUNT")")
  DEFAULT_IFACE=$(ask "主网卡名称" "$DEFAULT_IFACE")
  RX_QUEUES=$(to_int "$(ask "RX 队列数" "$RX_QUEUES")")
  TX_QUEUES=$(to_int "$(ask "TX 队列数" "$TX_QUEUES")")
  BUSY_MODE=$(ask_choice "busy_poll 模式" "$BUSY_MODE" auto force off)
}

edit_handshake() {
  banner
  printf '%s握手与应用层选项%s\n' "$BOLD" "$RESET"
  HANDSHAKE=$(ask_yes_no "是否启用 TFO 等建连优化" "$HANDSHAKE")
  LOCAL_TCP_TERMINATION=$(ask_yes_no "本机是否终止 TCP" "$LOCAL_TCP_TERMINATION")
  TFO_GLOBAL=$(ask_yes_no "是否启用全局监听 TFO 1024 位" "$TFO_GLOBAL")
  printf '\n应用层 mux/smux/yamux/multiplex 默认不启用，本脚本不会写 mux 配置。\n'
  pause_ui
}

edit_capacity() {
  banner
  printf '%s容量与高级覆盖%s\n' "$BOLD" "$RESET"
  TCP_CONNS_OVERRIDE=$(to_int "$(ask "TCP 并发覆盖，0=自动" "$TCP_CONNS_OVERRIDE")")
  UDP_SESSIONS_OVERRIDE=$(to_int "$(ask "UDP 会话覆盖，0=自动" "$UDP_SESSIONS_OVERRIDE")")
  CPS_OVERRIDE=$(to_int "$(ask "每秒新建连接覆盖，0=自动" "$CPS_OVERRIDE")")
  MANUAL_TCP_CAP_MB=$(to_int "$(ask "单连接 tcp_max 上限 MB，0=自动" "$MANUAL_TCP_CAP_MB")")
  MANUAL_BDP_MULT=$(to_int "$(ask "BDP 倍数覆盖，0=自动" "$MANUAL_BDP_MULT")")
  BBR_KIND=$(ask_choice "BBR 版本假设" "$BBR_KIND" bbr1 bbr3 unknown)
  SERVICE_NAME=$(ask "可选 systemd 服务名，用于 LimitNOFILE drop-in，空=跳过" "$SERVICE_NAME")
}

interactive_menu() {
  local choice key cursor=0 count=9 i answer
  local options=(
    "角色/场景/业务"
    "链路带宽/RTT/丢包抖动"
    "网卡/RPS/busy_poll"
    "TFO/握手优化/应用层说明"
    "并发容量/高级覆盖"
    "生成配置"
    "查看系统已生效参数"
    "清理旧输出目录"
    "退出"
  )
  tput civis 2>/dev/null || true
  while true; do
    banner
    if [[ "$DRAFT_DIRTY" == "yes" ]]; then
      show_summary
    else
      show_live_status_body
    fi
    hr
    printf '%s↑/↓ 或 j/k 选择，Enter 确认；也可按 1-9，q 退出%s\n\n' "$DIM" "$RESET"
    for ((i=0; i<count; i++)); do
      if (( i == cursor )); then
        printf '  %s> %d) %s%s\n' "$GREEN" $((i + 1)) "${options[$i]}" "$RESET"
      else
        printf '    %d) %s\n' $((i + 1)) "${options[$i]}"
      fi
    done

    choice=""
    if read_key key; then
      case "$key" in
        $'\e[A'|$'\eOA'|k|K) cursor=$(((cursor + count - 1) % count)); continue ;;
        $'\e[B'|$'\eOB'|j|J) cursor=$(((cursor + 1) % count)); continue ;;
        ""|$'\r'|$'\n') choice=$((cursor + 1)) ;;
        [1-9]) choice="$key"; cursor=$((choice - 1)) ;;
        q|Q) exit 0 ;;
        *) continue ;;
      esac
    else
      prompt_read choice "请选择 [6]: " || true
      choice="${choice:-6}"
    fi

    case "$choice" in
      1) edit_role_scene; DRAFT_DIRTY="yes" ;;
      2) edit_link; DRAFT_DIRTY="yes" ;;
      3) edit_runtime; DRAFT_DIRTY="yes" ;;
      4) edit_handshake; DRAFT_DIRTY="yes" ;;
      5) edit_capacity; DRAFT_DIRTY="yes" ;;
      6)
        if [[ "$DRAFT_DIRTY" == "yes" ]]; then
          break
        fi
        banner
        printf '当前主界面显示的是系统已生效参数，还没有待生效配置草案。\n'
        printf '建议先修改 1-5 项，再生成配置。\n\n'
        answer=$(ask_yes_no "仍然使用脚本默认草案生成配置" "no")
        if [[ "$answer" == "yes" ]]; then
          DRAFT_DIRTY="yes"
          break
        fi
        ;;
      7) show_live_status ;;
      8) clean_legacy_outputs ;;
      9|q|Q) exit 0 ;;
      *) warn "无效选择"; pause_ui ;;
    esac
  done
}

linear_wizard() {
  ROLE=$(ask_choice "机器角色" "$ROLE" forwarding landing)
  if [[ "$ROLE" == "forwarding" ]]; then
    SCENE=$(ask_choice "转发场景" "$SCENE" front ix relay international plain)
    STATEFUL=$(ask_yes_no "是否 NAT/TProxy/状态 nftables 规则" "$STATEFUL")
    LANDING_ROUTES="no"
  else
    SCENE="landing"
    LANDING_ROUTES=$(ask_yes_no "落地机是否同时做 NAT/路由" "$LANDING_ROUTES")
    [[ "$LANDING_ROUTES" == "yes" ]] && STATEFUL="yes" || STATEFUL="no"
  fi

  TARGET=$(ask_choice "优化目标" "$TARGET" speed throughput)
  BUSINESS=$(ask_choice "业务类型" "$BUSINESS" mixed tcp udp_game web)

  UP_MBPS=$(to_int "$(ask "上行/入口 Mbps" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "下行/出口 Mbps" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "上游 RTT ms" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "下游 RTT ms" "$DOWN_RTT")")
  LOSS_PCT=$(ask "丢包率百分比，例如 0 或 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "抖动 ms" "$JITTER_MS")")

  CPU_COUNT=$(to_int "$(ask "CPU 核数" "$CPU_COUNT")")
  DEFAULT_IFACE=$(ask "主网卡名称，用于 txqueuelen/RPS" "$DEFAULT_IFACE")
  RX_QUEUES=$(to_int "$(ask "RX 队列数" "$RX_QUEUES")")
  TX_QUEUES=$(to_int "$(ask "TX 队列数" "$TX_QUEUES")")

  MULTIPATH=$(ask_yes_no "是否多出口/策略路由/非对称回程" "$MULTIPATH")
  IPV6_RA=$(ask_yes_no "IPv6 默认路由是否依赖 RA" "$IPV6_RA")
  HANDSHAKE=$(ask_yes_no "是否启用 TFO 等建连优化" "$HANDSHAKE")
  if [[ "$ROLE" == "landing" ]]; then
    LOCAL_TCP_TERMINATION=$(ask_yes_no "落地机是否本机终止 TCP，例如 Xray/Web/代理监听服务" "$LOCAL_TCP_TERMINATION")
  else
    LOCAL_TCP_TERMINATION=$(ask_yes_no "这台转发机是否也终止 TCP，例如还有代理/Web 监听服务" "$LOCAL_TCP_TERMINATION")
  fi
  TFO_GLOBAL=$(ask_yes_no "是否启用全局监听 TFO 1024 位，通常选否" "$TFO_GLOBAL")
  BUSY_MODE=$(ask_choice "busy_poll 模式" "$BUSY_MODE" auto force off)
  MANUAL_TCP_CAP_MB=$(to_int "$(ask "单连接 tcp_max 上限 MB，0=自动" "$MANUAL_TCP_CAP_MB")")
  MANUAL_BDP_MULT=$(to_int "$(ask "BDP 倍数覆盖，0=自动" "$MANUAL_BDP_MULT")")
  BBR_KIND=$(ask_choice "BBR 版本假设" "$BBR_KIND" bbr1 bbr3 unknown)
  TCP_CONNS_OVERRIDE=$(to_int "$(ask "TCP 并发覆盖，0=自动" "$TCP_CONNS_OVERRIDE")")
  UDP_SESSIONS_OVERRIDE=$(to_int "$(ask "UDP 会话覆盖，0=自动" "$UDP_SESSIONS_OVERRIDE")")
  CPS_OVERRIDE=$(to_int "$(ask "每秒新建连接覆盖，0=自动" "$CPS_OVERRIDE")")
  SERVICE_NAME=$(ask "可选 systemd 服务名，用于 LimitNOFILE drop-in，空=跳过" "$SERVICE_NAME")
}

usage() {
  cat <<'USAGE'
中文 BBR 网络优化器 bbr.sh

交互式 Linux 网络优化脚本，面向极致专用转发节点和落地节点。

用法:
  bash bbr.sh             # 上下键可视化菜单，先生成配置，再确认是否应用
  bash bbr.sh --quick     # 线性问答模式
  bash bbr.sh --dry-run   # 只生成配置文件，不应用
  bash bbr.sh --apply     # 生成后默认询问应用
  bash bbr.sh --out-dir DIR       # 指定输出目录
  bash bbr.sh --clean-outputs     # 清理旧版 bbr-output-* 和 /root/network-optimize-backup-* 目录
  bash bbr.sh --help

默认输出目录:
  $HOME/.local/state/network-bbr-optimizer/runs/<时间戳>
  不再在当前目录刷出一堆 bbr-output-*。

默认备份目录:
  $HOME/.local/state/network-bbr-optimizer/backups/<时间戳>
  不再在 /root 下面刷出一堆 network-optimize-backup-*。

默认不启用应用层 mux/multiplex。

术语说明:
  BBR/BBR3: Linux TCP 拥塞控制算法名。
  TFO/TCP Fast Open: TCP 快速打开，只对本机主动连接或本机 TCP 监听服务有意义。
  RPS/RSS: 收包分流机制，用于多核处理网卡 RX 队列。
  nftables/conntrack/sysctl/systemd: Linux 防火墙、状态跟踪、内核参数和服务管理组件。
  fq/fq_codel/qdisc: Linux 队列调度器名。
  busy_poll/busy_read: Linux 低延迟轮询参数名。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) UI_MODE="wizard" ;;
    --dry-run) APPLY_MODE="no" ;;
    --apply) APPLY_MODE="yes" ;;
    --out-dir)
      shift
      [[ $# -gt 0 ]] || die "--out-dir 需要指定输出目录"
      OUT_DIR="$1"
      ;;
    --clean-outputs) CLEAN_OUTPUTS="yes" ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

is_linux() { [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]; }

need_linux() {
  is_linux || die "这个脚本只适合在 Linux 上运行。"
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

ask() {
  local prompt="$1" default="$2" value
  prompt_read value "$prompt [$default]: " || true
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  ask_choice "$1" "$2" yes no
}

ask_choice() {
  local prompt="$1" default="$2" value valid label label_name i
  shift 2
  local options=("$@")
  if has_tty && [[ -t 1 ]]; then
    select_option "$prompt" "$default" "${options[@]}"
    return
  fi
  while true; do
    printf '%s\n' "$prompt" >&2
    i=1
    for valid in "${options[@]}"; do
      printf '  %d) %s\n' "$i" "$(choice_label "$valid")" >&2
      i=$((i + 1))
    done
    prompt_read value "请选择编号或输入选项 [$(choice_label "$default")]: " || true
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= ${#options[@]} )); then
      printf '%s' "${options[$((value - 1))]}"
      return
    fi
    for valid in "${options[@]}"; do
      label="$(choice_label "$valid")"
      label_name="${label%% - *}"
      if [[ "$value" == "$valid" || "$value" == "$label" || "$value" == "$label_name" ]]; then
        printf '%s' "$valid"
        return
      fi
    done
    printf '无效选择，请输入编号、内部选项值或中文选项名。\n' >&2
  done
}

to_int() {
  awk -v n="${1:-0}" 'BEGIN { if (n < 0) n = 0; printf "%.0f", n }'
}

loss_to_bp() {
  awk -v n="${1:-0}" 'BEGIN { if (n < 0) n = 0; printf "%.0f", n * 100 }'
}

min() { (( $1 < $2 )) && printf '%s' "$1" || printf '%s' "$2"; }
max() { (( $1 > $2 )) && printf '%s' "$1" || printf '%s' "$2"; }

clamp() {
  local n="$1" lo="$2" hi="$3"
  if (( n < lo )); then
    printf '%s' "$lo"
  elif (( n > hi )); then
    printf '%s' "$hi"
  else
    printf '%s' "$n"
  fi
}

ceil_div() {
  local n="$1" d="$2"
  (( d > 0 )) || d=1
  printf '%s' $(((n + d - 1) / d))
}

pow2ceil() {
  local n="$1" p=1
  (( n < 1 )) && n=1
  while (( p < n )); do
    p=$((p << 1))
  done
  printf '%s' "$p"
}

round_up_mib() {
  local n="$1"
  printf '%s' $(( ((n + MIB - 1) / MIB) * MIB ))
}

sysctl_exists() {
  local key="$1" path
  path="/proc/sys/${key//./\/}"
  [[ -e "$path" ]]
}

read_sysctl() {
  local key="$1" fallback="$2"
  sysctl -n "$key" 2>/dev/null || printf '%s\n' "$fallback"
}

mem_kb() {
  awk -v key="$1" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' /proc/meminfo
}

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{
    for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }
  }'
}

count_queues() {
  local iface="$1" type="$2" dir count
  dir="/sys/class/net/$iface/queues"
  if [[ -d "$dir" ]]; then
    count=$(find "$dir" -maxdepth 1 -type d -name "${type}-*" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && printf '%s' "$count" && return
  fi
  printf '1'
}

cpu_count() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '1'
}

cpumask_all() {
  local cpus="$1" full rem i lower=() upper
  (( cpus < 1 )) && cpus=1
  full=$((cpus / 32))
  rem=$((cpus % 32))
  for ((i=0; i<full; i++)); do
    lower+=("ffffffff")
  done
  if (( rem > 0 )); then
    upper=$(printf '%x' $(((1 << rem) - 1)))
    lower+=("$upper")
  fi
  for ((i=${#lower[@]}-1; i>=0; i--)); do
    if (( i != ${#lower[@]}-1 )); then printf ','; fi
    printf '%s' "${lower[$i]}"
  done
}

emit_sysctl() {
  local key="$1" value="$2"
  if sysctl_exists "$key"; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_OUT"
  else
    printf '# 已跳过，当前内核缺少该参数: %s = %s\n' "$key" "$value" >> "$SYSCTL_OUT"
  fi
}

apply_generated_sysctl_live() {
  local file="$1" line key value
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$key" ]] || continue
    sysctl -w "$key=$value" >/dev/null 2>&1 || warn "运行时应用失败: $key=$value"
  done < "$file"
}

print_final_sysctl_status() {
  printf '\n最终生效检查:\n'
  print_live_sysctl net.ipv4.tcp_congestion_control
  print_live_sysctl net.core.default_qdisc
  print_live_sysctl net.ipv4.tcp_fastopen
  print_live_sysctl net.ipv4.ip_forward
  print_live_sysctl net.ipv6.conf.all.forwarding
  print_live_sysctl net.ipv4.conf.all.rp_filter
  print_live_sysctl net.netfilter.nf_conntrack_max
  print_live_sysctl net.core.busy_poll
}

backup_file() {
  local file="$1" backup_dir="$2"
  if [[ -e "$file" ]]; then
    mkdir -p "$backup_dir$(dirname "$file")"
    cp -a "$file" "$backup_dir$file"
  fi
}

install_file() {
  local src="$1" dst="$2" mode="$3" backup_dir="$4"
  backup_file "$dst" "$backup_dir"
  install -D -m "$mode" "$src" "$dst"
}

write_rollback() {
  local rollback="$OUT_DIR/rollback.sh" backup_dir="$1"
  cat > "$rollback" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="$backup_dir"
restore_or_remove() {
  local path="\$1"
  if [[ -e "\$BACKUP_DIR\$path" ]]; then
    mkdir -p "\$(dirname "\$path")"
    cp -a "\$BACKUP_DIR\$path" "\$path"
  else
    rm -f "\$path"
  fi
}
restore_or_remove /etc/sysctl.d/99-network-optimize.conf
restore_or_remove /etc/security/limits.d/99-network-optimize.conf
restore_or_remove /etc/systemd/system.conf.d/99-network-optimize.conf
restore_or_remove /etc/modprobe.d/nf_conntrack.conf
restore_or_remove /usr/local/sbin/network-optimize-route.sh
restore_or_remove /usr/local/sbin/network-optimize-nic.sh
restore_or_remove /etc/systemd/system/network-optimize-route.service
restore_or_remove /etc/systemd/system/network-optimize-nic.service
EOF
  if [[ -n "${SERVICE_NAME:-}" ]]; then
    printf 'restore_or_remove %q\n' "/etc/systemd/system/${SERVICE_NAME}.d/override.conf" >> "$rollback"
  fi
  cat >> "$rollback" <<'EOF'
systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
sysctl --system || true
echo "回滚文件已恢复。conntrack hashsize、路由 initcwnd 或网卡运行时状态可能需要重启网络或重启系统才会完全回退。"
EOF
  chmod +x "$rollback"
}

need_linux

TS="$(date +%Y%m%d-%H%M%S)"
if [[ "$CLEAN_OUTPUTS" == "yes" ]]; then
  clean_legacy_outputs
  exit 0
fi

STATE_DIR="$(default_state_dir)"

MEM_TOTAL_KB=$(mem_kb MemTotal)
MEM_AVAIL_KB=$(mem_kb MemAvailable)
if (( MEM_AVAIL_KB <= 0 )); then MEM_AVAIL_KB="$MEM_TOTAL_KB"; fi
CPU_COUNT=$(cpu_count)
DEFAULT_IFACE=$(detect_default_iface)
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"
RX_QUEUES=$(count_queues "$DEFAULT_IFACE" rx)
TX_QUEUES=$(count_queues "$DEFAULT_IFACE" tx)

ROLE="forwarding"
SCENE="plain"
TARGET="speed"
BUSINESS="mixed"
STATEFUL="yes"
LANDING_ROUTES="no"
IPV6_RA="no"
MULTIPATH="yes"
HANDSHAKE="yes"
TFO_GLOBAL="no"
LOCAL_TCP_TERMINATION="no"
BUSY_MODE="auto"
UP_MBPS=1000
DOWN_MBPS=1000
UP_RTT=80
DOWN_RTT=80
LOSS_PCT=0
JITTER_MS=0
MANUAL_TCP_CAP_MB=0
MANUAL_BDP_MULT=0
BBR_KIND="unknown"
TCP_CONNS_OVERRIDE=0
UDP_SESSIONS_OVERRIDE=0
CPS_OVERRIDE=0
SERVICE_NAME=""

if [[ "$UI_MODE" == "menu" && ( -t 0 || -r "$TTY_DEVICE" ) ]]; then
  interactive_menu
else
  linear_wizard
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$STATE_DIR/runs/$TS"
  OUT_DIR_AUTO="yes"
fi
mkdir -p "$OUT_DIR"
SYSCTL_OUT="$OUT_DIR/99-network-optimize.conf"
LIMITS_OUT="$OUT_DIR/99-network-optimize-limits.conf"
SYSTEMD_OUT="$OUT_DIR/99-network-optimize-system.conf"
MODPROBE_OUT="$OUT_DIR/nf_conntrack.conf"
ROUTE_OUT="$OUT_DIR/network-optimize-route.sh"
NIC_OUT="$OUT_DIR/network-optimize-nic.sh"
REPORT_OUT="$OUT_DIR/report.txt"

mkdir -p "$STATE_DIR" 2>/dev/null || true
ln -sfn "$OUT_DIR" "$STATE_DIR/latest" 2>/dev/null || true

printf '中文 BBR 网络优化器 bbr.sh %s\n' "$VERSION"
printf '输出目录: %s\n' "$OUT_DIR"
if [[ "$OUT_DIR_AUTO" == "yes" ]]; then
  printf '说明: 输出文件默认放在隐藏状态目录，不再堆在当前目录；latest 链接: %s/latest\n' "$STATE_DIR"
else
  printf '说明: 使用你指定的输出目录。\n'
fi
printf '\n'

LOSS_BP=$(loss_to_bp "$LOSS_PCT")

TCP_CONNS=350000
UDP_SESSIONS=150000
CPS=6000
MEM_PCT=64
if [[ "$ROLE" == "landing" ]]; then
  TCP_CONNS=260000
  UDP_SESSIONS=80000
  CPS=4500
fi

if (( MEM_TOTAL_KB < 1024 * 1024 )); then
  TCP_CONNS=$((TCP_CONNS / 4))
  UDP_SESSIONS=$((UDP_SESSIONS / 4))
  MEM_PCT=25
elif (( MEM_TOTAL_KB < 2048 * 1024 )); then
  TCP_CONNS=$((TCP_CONNS / 2))
  UDP_SESSIONS=$((UDP_SESSIONS / 2))
  MEM_PCT=40
fi

case "$BUSINESS" in
  mixed)
    UDP_SESSIONS=$((UDP_SESSIONS * 13 / 10))
    CPS=$((CPS * 11 / 10))
    ;;
  udp_game)
    UDP_SESSIONS=$((UDP_SESSIONS * 2))
    CPS=$((CPS * 3 / 2))
    ;;
  web)
    UDP_SESSIONS=$((UDP_SESSIONS / 2))
    CPS=$((CPS * 2))
    ;;
esac

if [[ "$ROLE" == "forwarding" ]]; then
  case "$SCENE" in
    front)
      TCP_CONNS=$((TCP_CONNS * 11 / 10))
      CPS=$((CPS * 14 / 10))
      ;;
    ix)
      TCP_CONNS=$((TCP_CONNS * 18 / 10))
      UDP_SESSIONS=$((UDP_SESSIONS * 2))
      CPS=$((CPS * 18 / 10))
      MEM_PCT=$((MEM_PCT + 12))
      ;;
    relay)
      TCP_CONNS=$((TCP_CONNS * 12 / 10))
      MEM_PCT=$((MEM_PCT + 6))
      ;;
    international)
      TCP_CONNS=$((TCP_CONNS * 11 / 10))
      UDP_SESSIONS=$((UDP_SESSIONS * 12 / 10))
      MEM_PCT=$((MEM_PCT + 4))
      ;;
  esac
fi

MEM_PCT=$((MEM_PCT + 14))
MEM_PCT=$(clamp "$MEM_PCT" 35 78)
if (( MEM_TOTAL_KB < 1024 * 1024 )); then
  MEM_PCT=$(clamp "$MEM_PCT" 1 25)
elif (( MEM_TOTAL_KB < 2048 * 1024 )); then
  MEM_PCT=$(clamp "$MEM_PCT" 1 40)
fi

if (( TCP_CONNS_OVERRIDE > 0 )); then TCP_CONNS="$TCP_CONNS_OVERRIDE"; fi
if (( UDP_SESSIONS_OVERRIDE > 0 )); then UDP_SESSIONS="$UDP_SESSIONS_OVERRIDE"; fi
if (( CPS_OVERRIDE > 0 )); then CPS="$CPS_OVERRIDE"; fi

UP_BDP=$((UP_MBPS * UP_RTT * 125))
DOWN_BDP=$((DOWN_MBPS * DOWN_RTT * 125))
BDP=$(max "$UP_BDP" "$DOWN_BDP")
MBW=$(max "$UP_MBPS" "$DOWN_MBPS")
MAXRTT=$(max "$UP_RTT" "$DOWN_RTT")

if [[ "$BBR_KIND" == "bbr3" ]]; then
  BDP_MULT=8
else
  BDP_MULT=10
fi
BDP_MULT=$((BDP_MULT + 2))
[[ "$BUSINESS" == "mixed" ]] && BDP_MULT=$((BDP_MULT + 1))
[[ "$BUSINESS" == "udp_game" ]] && BDP_MULT=$((BDP_MULT + 1))
(( LOSS_BP >= 100 )) && BDP_MULT=$((BDP_MULT + 1))
(( LOSS_BP >= 300 )) && BDP_MULT=$((BDP_MULT + 1))
JITTER_GUARD="no"
if (( JITTER_MS > MAXRTT / 2 + 1 )); then
  BDP_MULT=$((BDP_MULT + 1))
  JITTER_GUARD="yes"
fi
if [[ "$SCENE" == "ix" ]] && (( LOSS_BP < 100 )); then
  BDP_MULT=$((BDP_MULT + 2))
fi
if [[ "$SCENE" == "international" ]] && { (( LOSS_BP >= 100 )) || [[ "$JITTER_GUARD" == "yes" ]]; }; then
  BDP_MULT=$(min "$BDP_MULT" 12)
fi
if (( MANUAL_BDP_MULT > 0 )); then
  BDP_MULT="$MANUAL_BDP_MULT"
fi
BDP_MULT=$(clamp "$BDP_MULT" 2 16)
if (( LOSS_BP >= 100 )) || [[ "$JITTER_GUARD" == "yes" ]] || [[ "$BUSINESS" == "udp_game" ]]; then
  QUEUE_JITTER_GUARD="yes"
  BDP_MULT=$(min "$BDP_MULT" 12)
  NETDEV_BACKLOG_CAP=524288
  TXQUEUELEN_CAP=12000
  NETDEV_BUDGET_USECS_CAP=10000
else
  QUEUE_JITTER_GUARD="no"
  NETDEV_BACKLOG_CAP=1048576
  TXQUEUELEN_CAP=20000
  NETDEV_BUDGET_USECS_CAP=12000
fi

ACTIVE_DIV_RAW=$((TCP_CONNS / 5000 + UDP_SESSIONS / 25000 + 4))
ACTIVE_DIV_CAP=128
if [[ "$SCENE" == "ix" ]]; then
  ACTIVE_DIV_RAW=$((TCP_CONNS / 6000 + UDP_SESSIONS / 30000 + 4))
  ACTIVE_DIV_CAP=96
fi
ACTIVE_DIV=$(clamp "$ACTIVE_DIV_RAW" 4 "$ACTIVE_DIV_CAP")
MEM_AVAIL_BYTES=$((MEM_AVAIL_KB * 1024))
MEM_TOTAL_BYTES=$((MEM_TOTAL_KB * 1024))
MEM_CAP=$((MEM_AVAIL_BYTES * MEM_PCT / 100 / ACTIVE_DIV))
if (( MANUAL_TCP_CAP_MB > 0 )); then
  HARD_CAP=$((MANUAL_TCP_CAP_MB * MIB))
else
  HARD_CAP=$(min "$AUTO_TCP_CAP" "$MEM_CAP")
fi
HARD_CAP=$(max "$HARD_CAP" $((8 * MIB)))
DESIRED=$((BDP * BDP_MULT))
TCP_MAX=$(round_up_mib "$DESIRED")
TCP_MAX=$(max "$TCP_MAX" $((16 * MIB)))
TCP_MAX=$(min "$TCP_MAX" "$HARD_CAP")
TCP_MAX=$(max "$TCP_MAX" $((8 * MIB)))

read -r TCP_RMEM_MIN TCP_RMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_rmem '4096 87380 6291456')"
read -r TCP_WMEM_MIN TCP_WMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_wmem '4096 65536 4194304')"

ECN=0
[[ "$BBR_KIND" == "bbr3" ]] && ECN=2

TFO_VALUE=""
TFO_BLACKHOLE=""
if [[ "$HANDSHAKE" == "yes" ]]; then
  if [[ "$LOCAL_TCP_TERMINATION" == "yes" ]]; then
    TFO_VALUE=3
  else
    TFO_VALUE=""
  fi
  if [[ "$TFO_GLOBAL" == "yes" && -n "$TFO_VALUE" ]]; then
    TFO_VALUE=$((TFO_VALUE | 1024))
  fi
  if [[ -n "$TFO_VALUE" ]]; then
    if [[ "$SCENE" == "ix" && "$LOSS_BP" -lt 50 && "$QUEUE_JITTER_GUARD" == "no" ]]; then
      TFO_BLACKHOLE=0
    else
      TFO_BLACKHOLE=60
    fi
  fi
fi

if [[ "$TARGET" == "throughput" ]]; then
  LOWAT_FACTOR=384
  LOWAT_LO=$((128 * 1024))
  LOWAT_HI=$((2 * MIB))
else
  LOWAT_FACTOR=256
  LOWAT_LO=$((64 * 1024))
  LOWAT_HI=$((1 * MIB))
fi
LOWAT=$(clamp $((MBW * LOWAT_FACTOR)) "$LOWAT_LO" "$LOWAT_HI")

UDP_FACTOR=8192
[[ "$BUSINESS" == "mixed" ]] && UDP_FACTOR=12288
[[ "$TARGET" == "throughput" ]] && UDP_FACTOR=12288
[[ "$BUSINESS" == "udp_game" ]] && UDP_FACTOR=16384
UDPR="$BDP"
[[ "$BUSINESS" == "mixed" ]] && UDPR=$((BDP * 3 / 2))
[[ "$BUSINESS" == "udp_game" ]] && UDPR=$((BDP * 2))
UDPR=$(max "$UDPR" $((MBW * UDP_FACTOR)))
if [[ "$BUSINESS" == "udp_game" ]]; then
  UDP_SOCKET_CAP="$TCP_MAX"
elif [[ "$BUSINESS" == "mixed" ]]; then
  UDP_SOCKET_CAP=$((TCP_MAX * 3 / 4))
else
  UDP_SOCKET_CAP=$((TCP_MAX / 2))
fi
UDP_SOCKET_CAP=$(max "$UDP_SOCKET_CAP" "$MIB")
UDPR=$(clamp "$UDPR" "$MIB" "$UDP_SOCKET_CAP")
UDP_MIN=4096
[[ "$BUSINESS" == "mixed" ]] && UDP_MIN=16384
[[ "$BUSINESS" == "udp_game" ]] && UDP_MIN=16384
if [[ "$TARGET" == "throughput" || "$UDP_SESSIONS" -gt 50000 ]]; then UDP_MIN=8192; fi
UDP_MIN=$(clamp "$UDP_MIN" 4096 65536)
UDP_MAX_PAGES=$((MEM_AVAIL_KB * MEM_PCT / 400))
UDP_FLOOR=$(max $(( ($(ceil_div "$UDPR" 4096)) * 4 )) 4096)
UDP_CAP=$(max $((MEM_TOTAL_KB * MEM_PCT / 400)) "$UDP_FLOOR")
UDP_MAX_PAGES=$(clamp "$UDP_MAX_PAGES" "$UDP_FLOOR" "$UDP_CAP")
UDP_LOW=$((UDP_MAX_PAGES / 2))
UDP_PRESSURE=$((UDP_MAX_PAGES * 3 / 4))

OMEM_CAP=$(clamp $((TCP_MAX / 8)) "$MIB" $((16 * MIB)))
OPTMEM=$(clamp $((MBW * 256 + UDP_SESSIONS / 4)) $((256 * 1024)) "$OMEM_CAP")

if [[ "$BUSY_MODE" == "force" ]] || { [[ "$BUSY_MODE" == "auto" ]] && (( MBW >= 20 )) && { (( MAXRTT <= 20 )) || [[ "$BUSINESS" == "udp_game" && "$MAXRTT" -le 10 ]]; }; }; then
  BUSY_POLL=$(clamp $((20 + MBW / (CPU_COUNT + 1))) 20 400)
else
  BUSY_POLL=""
fi

if (( MAXRTT <= 10 )); then
  INITCWND=512
elif (( MAXRTT <= 50 )); then
  INITCWND=384
elif (( MAXRTT <= 120 )); then
  INITCWND=256
else
  INITCWND=160
fi
INITCWND=$(clamp "$INITCWND" 32 512)

MIN_RTT_WLEN=120
[[ "$TARGET" == "throughput" ]] && MIN_RTT_WLEN=180
MIN_RTT_WLEN=$((MIN_RTT_WLEN + (JITTER_MS + 9) / 10))
MIN_RTT_WLEN=$(clamp "$MIN_RTT_WLEN" 20 300)

REORDERING=$((128 + MAXRTT * 2 + JITTER_MS * 8 + LOSS_BP))
if [[ "$TARGET" == "throughput" ]]; then
  REORDERING=$((REORDERING * 13 / 10))
else
  REORDERING=$((REORDERING * 12 / 10))
fi
REORDERING=$(clamp "$REORDERING" 128 2000)

KEEP_TIME=30
KEEP_INTVL=10
KEEP_PROBES=3
if [[ "$BUSINESS" == "web" ]]; then
  KEEP_TIME=120
  KEEP_INTVL=20
  KEEP_PROBES=5
elif (( TCP_CONNS > 200000 )); then
  KEEP_TIME=45
  KEEP_INTVL=15
  KEEP_PROBES=4
fi

TCP_LIMIT_FACTOR=6
[[ "$TARGET" == "throughput" ]] && TCP_LIMIT_FACTOR=8
if [[ "$SCENE" == "ix" && "$LOSS_BP" -lt 50 ]]; then TCP_LIMIT_FACTOR=8; fi
if [[ "$SCENE" == "international" ]]; then TCP_LIMIT_FACTOR=5; fi
if (( LOSS_BP >= 100 )) || [[ "$QUEUE_JITTER_GUARD" == "yes" ]]; then TCP_LIMIT_FACTOR=4; fi
if [[ "$BUSINESS" == "udp_game" ]]; then TCP_LIMIT_FACTOR=3; fi
LIMIT_UPPER=$(clamp $((TCP_MAX / 2)) $((4 * MIB)) $((64 * MIB)))
TCP_LIMIT=$(clamp $((BDP * TCP_LIMIT_FACTOR)) "$MIB" "$LIMIT_UPPER")

SOMAXCONN=$(pow2ceil "$(clamp $((CPS * 4 + TCP_CONNS / 16)) 4096 1048576)")
SYN_BACKLOG=$(pow2ceil "$(clamp $((CPS * 8 + TCP_CONNS / 8)) 8192 1048576)")
FLOW_LIMIT=$(pow2ceil "$(clamp $((TCP_CONNS / 16 + UDP_SESSIONS / 8 + CPS * 2)) 4096 1048576)")
NOFILE=$(pow2ceil "$(clamp $(((TCP_CONNS + UDP_SESSIONS + CPS * 10) * 2 + 4096)) 65536 8388608)")
FS_FILE_MAX=$(pow2ceil "$(clamp $((NOFILE * 2)) 1048576 16777216)")

NETDEV_RAW=$((MBW * 16 + CPS * 8 + UDP_SESSIONS / 8))
NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$SCENE" == "ix" ]] && NETDEV_RAW=$((NETDEV_RAW * 2))
[[ "$TARGET" == "throughput" ]] && NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$BUSINESS" == "mixed" ]] && NETDEV_RAW=$((NETDEV_RAW + UDP_SESSIONS / 6))
[[ "$BUSINESS" == "udp_game" ]] && NETDEV_RAW=$((NETDEV_RAW + UDP_SESSIONS / 3))
NETDEV_BACKLOG=$(pow2ceil "$(clamp "$NETDEV_RAW" 4096 "$NETDEV_BACKLOG_CAP")")

CT_NEEDED="no"
if [[ "$ROLE" == "forwarding" && "$STATEFUL" == "yes" ]]; then CT_NEEDED="yes"; fi
if [[ "$ROLE" == "landing" && "$LANDING_ROUTES" == "yes" ]]; then CT_NEEDED="yes"; fi
CT_RAW=$((TCP_CONNS + UDP_SESSIONS * 2 + CPS * 90))
[[ "$SCENE" == "ix" ]] && CT_RAW=$((CT_RAW * 15 / 10))
[[ "$TARGET" == "throughput" ]] && CT_RAW=$((CT_RAW * 125 / 100))
[[ "$BUSINESS" == "mixed" ]] && CT_RAW=$((CT_RAW + UDP_SESSIONS / 2))
[[ "$BUSINESS" == "udp_game" ]] && CT_RAW=$((CT_RAW + UDP_SESSIONS))
CT_MEM_CAP=$((MEM_TOTAL_BYTES * MEM_PCT / 100 / 512))
CT_UPPER=$(min 16777216 "$(max 131072 "$CT_MEM_CAP")")
NF_CONNTRACK_MAX=$(clamp "$(pow2ceil "$CT_RAW")" 131072 "$CT_UPPER")
NF_CONNTRACK_BUCKETS=$(pow2ceil "$(clamp "$NF_CONNTRACK_MAX" 32768 16777216)")
CT_RESET_RAW=$((TCP_CONNS / 2 + UDP_SESSIONS + CPS * 30))
CT_RESET_MEM_CAP=$((MEM_TOTAL_BYTES / 8192))
CT_RESET_UPPER=$(min 2097152 "$(max 131072 "$CT_RESET_MEM_CAP")")
NF_CONNTRACK_RESET_MAX=$(clamp "$(pow2ceil "$CT_RESET_RAW")" 131072 "$CT_RESET_UPPER")
CT_COUNT_NOW="$(read_sysctl net.netfilter.nf_conntrack_count 0)"
if [[ "$CT_COUNT_NOW" =~ ^[0-9]+$ ]] && (( CT_COUNT_NOW > 0 )); then
  NF_CONNTRACK_RESET_MAX=$(max "$NF_CONNTRACK_RESET_MAX" "$(pow2ceil $((CT_COUNT_NOW * 2)))")
fi

CT_TCP_EST=900
[[ "$BUSINESS" == "web" ]] && CT_TCP_EST=1200
(( TCP_CONNS > 500000 )) && CT_TCP_EST=600
CT_UDP=45
[[ "$BUSINESS" == "mixed" ]] && CT_UDP=35
[[ "$BUSINESS" == "udp_game" ]] && CT_UDP=30
CT_UDP_STREAM=180

TXQUEUELEN=$((MBW / 2 + MAXRTT * 10 + UDP_SESSIONS / 1000))
TXQUEUELEN=$((TXQUEUELEN * 15 / 10))
[[ "$TARGET" == "throughput" ]] && TXQUEUELEN=$((TXQUEUELEN * 13 / 10))
[[ "$BUSINESS" == "mixed" ]] && TXQUEUELEN=$((TXQUEUELEN + 250))
[[ "$BUSINESS" == "udp_game" ]] && TXQUEUELEN=$((TXQUEUELEN + 500))
TXQUEUELEN=$(clamp "$TXQUEUELEN" 500 "$TXQUEUELEN_CAP")

RX_QUEUES=$(max "$RX_QUEUES" 1)
NETDEV_BUDGET=$(clamp $((RX_QUEUES * 800)) 1600 20000)
NETDEV_BUDGET_USECS=$(clamp 10000 1 "$NETDEV_BUDGET_USECS_CAP")
[[ "$TARGET" == "throughput" ]] && NETDEV_BUDGET_USECS=$(clamp 12000 1 "$NETDEV_BUDGET_USECS_CAP")

RPS_ENABLE="no"
if (( RX_QUEUES < CPU_COUNT && CPU_COUNT >= 2 )); then
  RPS_ENABLE="yes"
fi
RPS_ENTRIES=$(clamp "$FLOW_LIMIT" 32768 2097152)
RPS_FLOW_CNT=$(clamp $((RPS_ENTRIES / RX_QUEUES)) 1024 65536)
RPS_CPUS=$(cpumask_all "$CPU_COUNT")

RP_FILTER=2
[[ "$MULTIPATH" == "yes" ]] && RP_FILTER=0

: > "$SYSCTL_OUT"
{
  printf '# 由 bbr.sh %s 生成，时间: %s\n' "$VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# 角色=%s 场景=%s 目标=%s 业务=%s\n\n' "$(role_label)" "$(scene_label)" "$(target_label)" "$(business_label)"
} >> "$SYSCTL_OUT"

emit_sysctl net.core.default_qdisc fq
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  emit_sysctl net.ipv4.tcp_congestion_control bbr
else
  printf '# 已跳过: net.ipv4.tcp_available_congestion_control 中没有 bbr\n' >> "$SYSCTL_OUT"
fi
emit_sysctl fs.file-max "$FS_FILE_MAX"
emit_sysctl net.core.rmem_max "$TCP_MAX"
emit_sysctl net.core.wmem_max "$TCP_MAX"
emit_sysctl net.ipv4.tcp_rmem "$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_MAX"
emit_sysctl net.ipv4.tcp_wmem "$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_MAX"
emit_sysctl net.ipv4.tcp_moderate_rcvbuf 1
emit_sysctl net.core.optmem_max "$OPTMEM"
emit_sysctl net.ipv4.tcp_notsent_lowat "$LOWAT"
emit_sysctl net.ipv4.tcp_slow_start_after_idle 0
emit_sysctl net.ipv4.tcp_min_rtt_wlen "$MIN_RTT_WLEN"
emit_sysctl net.ipv4.tcp_max_reordering "$REORDERING"
emit_sysctl net.ipv4.tcp_ecn "$ECN"
if [[ -n "$TFO_VALUE" ]]; then
  emit_sysctl net.ipv4.tcp_fastopen "$TFO_VALUE"
  [[ -n "$TFO_BLACKHOLE" ]] && emit_sysctl net.ipv4.tcp_fastopen_blackhole_timeout_sec "$TFO_BLACKHOLE"
else
  printf '# 已跳过: 纯内核转发且本机不终止 TCP 时，tcp_fastopen 对被转发连接没有实际帮助\n' >> "$SYSCTL_OUT"
  emit_sysctl net.ipv4.tcp_fastopen 0
fi
emit_sysctl net.ipv4.tcp_mtu_probing 1
emit_sysctl net.ipv4.tcp_rfc1337 1
emit_sysctl net.ipv4.tcp_keepalive_time "$KEEP_TIME"
emit_sysctl net.ipv4.tcp_keepalive_intvl "$KEEP_INTVL"
emit_sysctl net.ipv4.tcp_keepalive_probes "$KEEP_PROBES"
emit_sysctl net.ipv4.tcp_limit_output_bytes "$TCP_LIMIT"
emit_sysctl net.core.somaxconn "$SOMAXCONN"
emit_sysctl net.ipv4.tcp_max_syn_backlog "$SYN_BACKLOG"
emit_sysctl net.ipv4.ip_local_port_range "1024 65535"
emit_sysctl net.core.flow_limit_table_len "$FLOW_LIMIT"
emit_sysctl net.ipv4.udp_rmem_min "$UDP_MIN"
emit_sysctl net.ipv4.udp_wmem_min "$UDP_MIN"
emit_sysctl net.ipv4.udp_mem "$UDP_LOW $UDP_PRESSURE $UDP_MAX_PAGES"
emit_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
emit_sysctl net.core.netdev_budget "$NETDEV_BUDGET"
emit_sysctl net.core.netdev_budget_usecs "$NETDEV_BUDGET_USECS"
emit_sysctl net.core.rps_sock_flow_entries "$RPS_ENTRIES"

if [[ "$ROLE" == "forwarding" || "$LANDING_ROUTES" == "yes" ]]; then
  emit_sysctl net.ipv4.ip_forward 1
  emit_sysctl net.ipv4.conf.all.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.default.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.all.accept_source_route 0
  emit_sysctl net.ipv4.conf.default.accept_source_route 0
  emit_sysctl net.ipv4.conf.all.send_redirects 0
  emit_sysctl net.ipv4.conf.default.send_redirects 0
  emit_sysctl net.ipv4.conf.all.accept_redirects 0
  emit_sysctl net.ipv4.conf.default.accept_redirects 0
  emit_sysctl net.ipv6.conf.all.forwarding 1
  emit_sysctl net.ipv6.conf.default.forwarding 1
  emit_sysctl net.ipv6.conf.all.accept_redirects 0
  emit_sysctl net.ipv6.conf.default.accept_redirects 0
  emit_sysctl net.ipv6.conf.all.accept_source_route 0
  emit_sysctl net.ipv6.conf.default.accept_source_route 0
  if [[ "$IPV6_RA" == "yes" ]]; then
    printf '# IPv6 默认路由依赖 %s 的 RA：如需保留默认路由，请在接口级单独设置 accept_ra=2，不要写到 all/default。\n' "$DEFAULT_IFACE" >> "$SYSCTL_OUT"
  fi
else
  printf '# 落地节点未启用 NAT/路由：显式关闭以前可能残留的内核转发。\n' >> "$SYSCTL_OUT"
  emit_sysctl net.ipv4.ip_forward 0
  emit_sysctl net.ipv6.conf.all.forwarding 0
  emit_sysctl net.ipv6.conf.default.forwarding 0
  emit_sysctl net.ipv4.conf.all.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.default.rp_filter "$RP_FILTER"
fi

if [[ "$CT_NEEDED" == "yes" ]]; then
  emit_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_MAX"
  emit_sysctl net.netfilter.nf_conntrack_tcp_timeout_established "$CT_TCP_EST"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout "$CT_UDP"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout_stream "$CT_UDP_STREAM"
else
  printf '# 当前角色不需要本脚本放大 conntrack；这里写入安全回落值，覆盖旧转发配置残留。\n' >> "$SYSCTL_OUT"
  emit_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_RESET_MAX"
fi

if [[ -n "$BUSY_POLL" ]]; then
  emit_sysctl net.core.busy_poll "$BUSY_POLL"
  emit_sysctl net.core.busy_read "$BUSY_POLL"
else
  emit_sysctl net.core.busy_poll 0
  emit_sysctl net.core.busy_read 0
fi

cat > "$LIMITS_OUT" <<EOF
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF

cat > "$SYSTEMD_OUT" <<EOF
[Manager]
DefaultLimitNOFILE=$NOFILE
EOF

if [[ "$CT_NEEDED" == "yes" ]]; then
  cat > "$MODPROBE_OUT" <<EOF
options nf_conntrack hashsize=$NF_CONNTRACK_BUCKETS
EOF
else
  cat > "$MODPROBE_OUT" <<'EOF'
# 当前配置不需要本脚本设置 nf_conntrack hashsize。
# 这个文件会覆盖旧版脚本留下的 hashsize 配置，避免转发配置切换到落地配置后继续残留。
EOF
fi

cat > "$ROUTE_OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
apply_init() {
  local family="\$1" line clean
  local -a route_parts
  if [[ "\$family" == "4" ]]; then
    ip route show default 2>/dev/null
  else
    ip -6 route show default 2>/dev/null
  fi | while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    clean=\$(printf '%s' "\$line" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')
    read -r -a route_parts <<< "\$clean"
    if [[ "\$family" == "4" ]]; then
      ip route replace "\${route_parts[@]}" initcwnd $INITCWND initrwnd $INITCWND || true
    else
      ip -6 route replace "\${route_parts[@]}" initcwnd $INITCWND initrwnd $INITCWND || true
    fi
  done
}
apply_init 4
apply_init 6
EOF
chmod +x "$ROUTE_OUT"

cat > "$NIC_OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFACE="${DEFAULT_IFACE}"
TXQ="$TXQUEUELEN"
RPS_ENABLE="$RPS_ENABLE"
RPS_CPUS="$RPS_CPUS"
RPS_FLOW_CNT="$RPS_FLOW_CNT"
if [[ -d "/sys/class/net/\$IFACE" ]]; then
  ip link set dev "\$IFACE" txqueuelen "\$TXQ" || true
  if [[ "\$RPS_ENABLE" == "yes" ]]; then
    for f in /sys/class/net/"\$IFACE"/queues/rx-*/rps_cpus; do
      [[ -e "\$f" ]] && printf '%s' "\$RPS_CPUS" > "\$f" || true
    done
    for f in /sys/class/net/"\$IFACE"/queues/rx-*/rps_flow_cnt; do
      [[ -e "\$f" ]] && printf '%s' "\$RPS_FLOW_CNT" > "\$f" || true
    done
  fi
fi
EOF
chmod +x "$NIC_OUT"

if [[ -n "$SERVICE_NAME" ]]; then
  SERVICE_DROPIN="$OUT_DIR/${SERVICE_NAME}.override.conf"
  cat > "$SERVICE_DROPIN" <<EOF
[Service]
LimitNOFILE=$NOFILE
EOF
fi

cat > "$REPORT_OUT" <<EOF
中文 BBR 网络优化器报告
======================
角色=$(role_label)
场景=$(scene_label)
目标=$(target_label)
业务=$(business_label)
主网卡=$DEFAULT_IFACE
上行_Mbps=$UP_MBPS
下行_Mbps=$DOWN_MBPS
上游_RTT_ms=$UP_RTT
下游_RTT_ms=$DOWN_RTT
丢包率_pct=$LOSS_PCT
抖动_ms=$JITTER_MS
队列抖动保护=$QUEUE_JITTER_GUARD

TCP并发=$TCP_CONNS
UDP会话=$UDP_SESSIONS
每秒新建连接=$CPS
内存预算_pct=$MEM_PCT
BDP_bytes=$BDP
BDP倍数=$BDP_MULT
TCP缓冲上限=$TCP_MAX
tcp_limit_output_bytes=$TCP_LIMIT
initcwnd=$INITCWND
nofile=$NOFILE
netdev_max_backlog=$NETDEV_BACKLOG
txqueuelen=$TXQUEUELEN
RPS启用=$RPS_ENABLE
RPS_CPU掩码=$RPS_CPUS
RPS单队列流表=$RPS_FLOW_CNT
TFO值=${TFO_VALUE:-已跳过}
TFO黑洞检测=${TFO_BLACKHOLE:-已跳过}
需要conntrack=$CT_NEEDED
nf_conntrack_max=$NF_CONNTRACK_MAX
nf_conntrack_buckets=$NF_CONNTRACK_BUCKETS
不需要conntrack时的安全回落上限=$NF_CONNTRACK_RESET_MAX

应用层 mux/multiplex：本脚本不会开启。
EOF

printf '\n已生成文件:\n'
printf '  %s\n' "$SYSCTL_OUT" "$LIMITS_OUT" "$SYSTEMD_OUT" "$ROUTE_OUT" "$NIC_OUT" "$REPORT_OUT"
printf '  %s\n' "$MODPROBE_OUT"
[[ -n "${SERVICE_DROPIN:-}" ]] && printf '  %s\n' "$SERVICE_DROPIN"

if [[ "$APPLY_MODE" == "no" ]]; then
  log "只生成配置完成。请检查输出目录: $OUT_DIR"
  exit 0
fi

if ! is_root; then
  warn "当前不是 root，只生成配置文件；如需应用请使用 sudo 重新运行。"
  exit 0
fi

if [[ "$APPLY_MODE" == "ask" ]]; then
  DO_APPLY=$(ask_yes_no "现在应用刚生成的配置吗" "no")
else
  DO_APPLY=$(ask_yes_no "现在应用刚生成的配置吗" "yes")
fi
if [[ "$DO_APPLY" != "yes" ]]; then
  log "未应用配置。请检查输出目录: $OUT_DIR"
  exit 0
fi

BACKUP_DIR="$STATE_DIR/backups/$TS"
mkdir -p "$BACKUP_DIR"
ln -sfn "$BACKUP_DIR" "$STATE_DIR/latest-backup" 2>/dev/null || true
write_rollback "$BACKUP_DIR"

install_file "$SYSCTL_OUT" /etc/sysctl.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$LIMITS_OUT" /etc/security/limits.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$SYSTEMD_OUT" /etc/systemd/system.conf.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$MODPROBE_OUT" /etc/modprobe.d/nf_conntrack.conf 0644 "$BACKUP_DIR"
install_file "$ROUTE_OUT" /usr/local/sbin/network-optimize-route.sh 0755 "$BACKUP_DIR"
install_file "$NIC_OUT" /usr/local/sbin/network-optimize-nic.sh 0755 "$BACKUP_DIR"

cat > "$OUT_DIR/network-optimize-route.service" <<'EOF'
[Unit]
Description=应用网络优化路由 initcwnd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/network-optimize-route.sh

[Install]
WantedBy=multi-user.target
EOF
cat > "$OUT_DIR/network-optimize-nic.service" <<'EOF'
[Unit]
Description=应用网络优化网卡 txqueuelen 和 RPS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/network-optimize-nic.sh

[Install]
WantedBy=multi-user.target
EOF
install_file "$OUT_DIR/network-optimize-route.service" /etc/systemd/system/network-optimize-route.service 0644 "$BACKUP_DIR"
install_file "$OUT_DIR/network-optimize-nic.service" /etc/systemd/system/network-optimize-nic.service 0644 "$BACKUP_DIR"

if [[ -n "${SERVICE_DROPIN:-}" ]]; then
  install_file "$SERVICE_DROPIN" "/etc/systemd/system/${SERVICE_NAME}.d/override.conf" 0644 "$BACKUP_DIR"
fi

sysctl --system
apply_generated_sysctl_live "$SYSCTL_OUT"
if [[ "$CT_NEEDED" != "yes" ]] && sysctl_exists net.netfilter.nf_conntrack_max; then
  CT_CURRENT="$(read_sysctl net.netfilter.nf_conntrack_max 0)"
  CT_COUNT="$(read_sysctl net.netfilter.nf_conntrack_count 0)"
  if [[ "$CT_CURRENT" =~ ^[0-9]+$ && "$CT_COUNT" =~ ^[0-9]+$ ]] && (( CT_CURRENT > NF_CONNTRACK_RESET_MAX )); then
    if (( CT_COUNT < NF_CONNTRACK_RESET_MAX )); then
      sysctl -w "net.netfilter.nf_conntrack_max=$NF_CONNTRACK_RESET_MAX" >/dev/null 2>&1 || \
        warn "nf_conntrack_max 当前运行值未能降回 $NF_CONNTRACK_RESET_MAX，重启后会按系统默认重新计算。"
    else
      warn "当前 conntrack 已用 $CT_COUNT，暂不把 nf_conntrack_max 降到 $NF_CONNTRACK_RESET_MAX，避免影响现有连接。"
    fi
  fi
fi
systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now network-optimize-route.service 2>/dev/null || true
systemctl enable --now network-optimize-nic.service 2>/dev/null || true
print_final_sysctl_status

printf '\n已应用配置。回滚脚本: %s/rollback.sh\n' "$OUT_DIR"
printf '备份目录: %s\n' "$BACKUP_DIR"
printf '如果 nf_conntrack hashsize 发生变化，建议重启系统让它完整生效。\n'
