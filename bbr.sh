#!/usr/bin/env bash
set -euo pipefail

VERSION="2026.06.30.1"
MIB=1048576
AUTO_TCP_CAP=$((2047 * MIB))

# 术语备注：
# BBR/BBR3：Linux TCP 拥塞控制算法名，保留英文。
# TFO/TCP Fast Open：TCP 快速打开，减少本机主动连接或本机监听服务的握手等待。
# RPS/RSS：网卡/内核收包分流机制，保留英文缩写。
# nftables/conntrack/sysctl/systemd：Linux 内核转发、防火墙状态跟踪、内核参数和服务管理组件名。
# fq/fq_codel/qdisc：Linux 队列调度器名，保留英文。
# busy_poll/busy_read：Linux 低延迟轮询参数名，保留英文。
# initcwnd/initrwnd/txqueuelen/nofile：路由初始窗口、网卡发送队列和文件描述符限制参数名；新版默认只清理旧窗口残留，不再强写。

ROLE=""
SCENE=""
TARGET="speed"
BUSINESS="udp_game"
CONCURRENCY_MODE="auto"
STATEFUL="auto"
LANDING_ROUTES="auto"
IPV6_RA="auto"
MULTIPATH="auto"
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
WGMIMIC_REQUIRED_ONLY="no"
CHINA_WHITELIST_ONLY="no"
CHINA_WHITELIST_RAW_BASE="${CHINA_WHITELIST_RAW_BASE:-https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main}"
CHINA_WHITELIST_ENTRYPOINT="${CHINA_WHITELIST_ENTRYPOINT:-bootstrap.sh}"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-${BBR_GITHUB_PROXY_URL:-https://gh-proxy.com/}}"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

TTY_DEVICE="${TTY_DEVICE:-/dev/tty}"

if { [[ -t 1 ]] || [[ -r "$TTY_DEVICE" && -w "$TTY_DEVICE" ]]; } && [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
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
    yes) printf 'yes 是 - 开启/确认' ;;
    no) printf 'no 否 - 关闭/不启用' ;;
    forwarding) printf 'forwarding 转发节点 - nftables/路由内核转发机器' ;;
    front) printf 'front 前置入口 - 用户进入的第一跳转发' ;;
    relay) printf 'relay 中继转发 - 跨网、跨境、WG/Mimic 或公网中继' ;;
    ix) printf 'ix 专线/IX 转发 - 专线/IX 汇聚，低抖动转发' ;;
    landing) printf 'landing 落地出口 - 本机代理/隧道出口，终止 TCP/UDP 会话' ;;
    hybrid) printf 'hybrid 混合网络节点 - 本机终止和转发链路并存' ;;
    aws) printf 'aws 兼容旧选项 - 按 hybrid 混合网络节点计算' ;;
    international) printf 'international 兼容旧选项 - 按 relay 中继转发计算' ;;
    speed) printf 'speed 响应优先 - 游戏/实时小包优先，兼顾起速' ;;
    throughput) printf 'throughput 极致吞吐 - 更偏大流量长时间持续吞吐' ;;
    mixed) printf 'mixed TCP+UDP 双优化 - 默认同时照顾 TCP 满速和 UDP 会话' ;;
    tcp) printf 'tcp TCP 长连接 - 长连接、代理隧道或大流量 TCP' ;;
    udp_game) printf 'udp_game UDP 游戏/实时 - 游戏、语音、实时 UDP，默认低排队' ;;
    web) printf 'web HTTP/API - HTTP、API、短连接 HTTPS 流量' ;;
    balanced) printf 'balanced 均衡并发 - 按带宽/内存自动估算会话表' ;;
    high) printf 'high 高并发 - 提高 conntrack/nofile/backlog 容量' ;;
    extreme) printf 'extreme 极高并发 - 更激进提高会话容量，仍受内存保护' ;;
    auto) printf 'auto 自动 - 按当前参数自动判断' ;;
    force) printf 'force 强制开启 - 跳过自动判断直接启用' ;;
    off) printf 'off 关闭 - 不启用该项' ;;
    bbr1) printf 'BBR1 - 按常见 BBR1 内核计算' ;;
    bbr3) printf 'BBR3 - 仅在确认内核是 BBR3 时选择' ;;
    unknown) printf 'unknown 未知 - 不确定版本时使用，按 BBR1/未知保守计算' ;;
    *) printf '%s' "$1" ;;
  esac
}

choice_short_label() {
  case "$1" in
    yes|no) yn_label "$1" ;;
    auto) printf '自动' ;;
    balanced) printf '均衡并发' ;;
    high) printf '高并发' ;;
    extreme) printf '极高并发' ;;
    force) printf '强制开启' ;;
    off) printf '关闭' ;;
    bbr1) printf 'BBR1' ;;
    bbr3) printf 'BBR3' ;;
    unknown) printf '未知' ;;
    *) printf '%s' "$1" ;;
  esac
}

normalize_scene_choice() {
  case "${1:-}" in
    aws) printf 'hybrid' ;;
    international) printf 'relay' ;;
    *) printf '%s' "${1:-}" ;;
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
  printf '%sNetwork BBR Optimizer / 中文 BBR 网络优化器%s  %s%s%s\n' "$BOLD" "$RESET" "$CYAN" "$VERSION" "$RESET"
  printf '固定策略: 游戏低延迟 + UDP 实时优先 + 可控吞吐 | 默认不启用应用层 mux\n'
  printf '术语: BBR/TFO/RPS/nftables/conntrack/sysctl 保留英文；选项内附中文备注\n'
  hr
}

github_proxy_url() {
  local raw_url="$1" proxy="$2"
  case "$proxy" in
    ""|direct|none)
      printf '%s\n' "$raw_url"
      ;;
    */)
      printf '%s%s\n' "$proxy" "$raw_url"
      ;;
    *)
      printf '%s/%s\n' "$proxy" "$raw_url"
      ;;
  esac
}

china_whitelist_proxy_candidates() {
  local candidates mode
  candidates="${CHINA_WHITELIST_GITHUB_PROXIES:-${CN_GITHUB_PROXIES:-${BBR_GITHUB_PROXIES:-}}}"
  if [[ -n "$candidates" ]]; then
    printf '%s\n' "${candidates//,/ }"
    return 0
  fi

  mode="${CHINA_WHITELIST_GITHUB_PROXY:-${CN_GITHUB_PROXY:-${BBR_GITHUB_PROXY:-auto}}}"
  case "$mode" in
    ""|auto)
      printf '%s direct\n' "$GITHUB_PROXY_PREFIX"
      ;;
    direct|none|0|no|NO|No|false|FALSE|False|off|OFF|Off)
      printf 'direct\n'
      ;;
    1|yes|YES|Yes|true|TRUE|True|on|ON|On|force)
      printf '%s direct\n' "$GITHUB_PROXY_PREFIX"
      ;;
    *)
      printf '%s direct\n' "$mode"
      ;;
  esac
}

run_china_region_whitelist() {
  local pause_after="${1:-yes}" tmp proxy url status
  banner
  printf '%schina-region-whitelist / 中国地区白名单%s\n' "$BOLD" "$RESET"
  printf '将拉取并运行 GHUNLIL/china-region-whitelist 的 %s。\n' "$CHINA_WHITELIST_ENTRYPOINT"
  printf '默认代理优先，失败会尝试直连；可用 CHINA_WHITELIST_GITHUB_PROXY=direct 强制直连。\n\n'

  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法拉取 china-region-whitelist。"
  command -v mktemp >/dev/null 2>&1 || die "缺少 mktemp，无法创建临时文件。"
  tmp="$(mktemp "/tmp/china-region-whitelist.XXXXXX")" || die "mktemp 失败"

  for proxy in $(china_whitelist_proxy_candidates); do
    url="$(github_proxy_url "${CHINA_WHITELIST_RAW_BASE%/}/${CHINA_WHITELIST_ENTRYPOINT}" "$proxy")"
    log "正在下载：$url"
    if curl -fL --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 1 -o "$tmp" "$url"; then
      chmod +x "$tmp"
      set +e
      CN_GITHUB_PROXY="${CN_GITHUB_PROXY:-$proxy}" \
        GITHUB_PROXY_PREFIX="$GITHUB_PROXY_PREFIX" \
        bash "$tmp"
      status=$?
      set -e
      rm -f "$tmp"
      [[ "$pause_after" == "yes" ]] && pause_ui
      return "$status"
    fi
    warn "下载失败，尝试下一个地址。"
  done

  rm -f "$tmp"
  warn "无法下载 china-region-whitelist，请检查网络或设置 CHINA_WHITELIST_GITHUB_PROXY=https://gh-proxy.com/"
  [[ "$pause_after" == "yes" ]] && pause_ui
  return 1
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
  case "${SCENE:-relay}" in
    front) printf '前置入口' ;;
    relay|international) printf '中继转发' ;;
    ix) printf '专线/IX 转发' ;;
    landing) printf '落地出口' ;;
    hybrid|aws) printf '混合网络节点' ;;
    *) printf '%s' "$SCENE" ;;
  esac
}

target_label() {
  case "${TARGET:-speed}" in
    speed) printf '响应优先' ;;
    throughput) printf '极致吞吐' ;;
    *) printf '%s' "$TARGET" ;;
  esac
}

business_label() {
  case "${BUSINESS:-udp_game}" in
    mixed) printf 'TCP+UDP 双优化' ;;
    tcp) printf 'TCP 长连接' ;;
    udp_game) printf 'UDP 游戏/实时' ;;
    web) printf 'HTTP/API 短连接' ;;
    *) printf '%s' "$BUSINESS" ;;
  esac
}

show_summary() {
  infer_auto_topology
  printf '%s待生效配置草案%s\n' "$BOLD" "$RESET"
  printf '  说明            : 这里是你修改后的待生成/待应用配置，不是当前系统已生效值。\n'
  printf '  转发场景        : %s（默认角色：%s）\n' "$(scene_label)" "$(role_label)"
  printf '  固定策略        : %s / %s\n' "$(target_label)" "$(business_label)"
  printf '  带宽 Mbps      : 上行 %s / 下行 %s\n' "$UP_MBPS" "$DOWN_MBPS"
  printf '  RTT ms         : 上游 %s / 下游 %s\n' "$UP_RTT" "$DOWN_RTT"
  printf '  丢包/抖动      : %s%% / %sms\n' "$LOSS_PCT" "$JITTER_MS"
  printf '  自动检测        : 网卡 %s / RX %s / TX %s / CPU %s\n' "$DEFAULT_IFACE" "$RX_QUEUES" "$TX_QUEUES" "$CPU_COUNT"
  printf '  自动拓扑        : 状态规则=%s, 落地路由=%s, 多出口/策略路由=%s, IPv6 RA=%s\n' \
    "$(yn_label "$STATEFUL")" "$(yn_label "$LANDING_ROUTES")" "$(yn_label "$MULTIPATH")" "$(yn_label "$IPV6_RA")"
  printf '  自动策略        : TFO=%s, 本机终止 TCP=%s, 全局监听 TFO=%s, busy_poll=%s\n' \
    "$(yn_label "$HANDSHAKE")" "$(yn_label "$LOCAL_TCP_TERMINATION")" "$(yn_label "$TFO_GLOBAL")" "$(choice_short_label "$BUSY_MODE")"
  printf '  自动容量        : 会话表强度=%s, TCP/UDP/CPS/BDP 覆盖均为自动\n' "$(choice_short_label "$CONCURRENCY_MODE")"
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
    printf '  %-46s %s\n' "$key" "not available (当前内核不存在)"
  fi
}

show_live_status_body() {
  printf '%s系统已生效参数%s\n' "$BOLD" "$RESET"
  printf '  说明            : 以下为从当前系统实时读取的值；修改 1-2 项后，主界面会切换为待生效配置草案。\n'
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

show_live_status_preview() {
  printf '%s系统已生效参数预览%s\n' "$BOLD" "$RESET"
  printf '  默认网卡        : %s / RX %s / TX %s / CPU %s\n' "$DEFAULT_IFACE" "$RX_QUEUES" "$TX_QUEUES" "$CPU_COUNT"
  print_live_sysctl net.ipv4.tcp_congestion_control
  print_live_sysctl net.core.default_qdisc
  print_live_sysctl net.ipv4.tcp_fastopen
  print_live_sysctl net.ipv4.ip_forward
  print_live_sysctl net.ipv6.conf.all.forwarding
  print_live_sysctl net.ipv4.conf.all.rp_filter
  printf '  %s完整列表请选 live sysctl%s\n' "$DIM" "$RESET"
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

apply_scene_defaults() {
  SCENE="$(normalize_scene_choice "${SCENE:-relay}")"
  case "${SCENE:-relay}" in
    landing)
      ROLE="landing"
      TARGET="speed"
      BUSINESS="mixed"
      ;;
    hybrid)
      ROLE="forwarding"
      TARGET="speed"
      BUSINESS="mixed"
      ;;
    front|ix|relay)
      ROLE="forwarding"
      TARGET="speed"
      BUSINESS="udp_game"
      ;;
    *)
      ROLE="forwarding"
      SCENE="relay"
      TARGET="speed"
      BUSINESS="udp_game"
      ;;
  esac
}

edit_scene() {
  banner
  printf '%sscene 转发场景%s\n' "$BOLD" "$RESET"
  SCENE=$(ask_choice "scene 转发场景" "${SCENE:-relay}" front relay ix landing hybrid)
  apply_scene_defaults
  infer_auto_topology
}

edit_link() {
  banner
  printf '%sbandwidth / RTT / loss 链路参数%s\n' "$BOLD" "$RESET"
  UP_MBPS=$(to_int "$(ask "upload/ingress Mbps 上行/入口带宽" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "download/egress Mbps 下行/出口带宽" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "upstream RTT ms 到上一跳/入口侧延迟" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "downstream RTT ms 到下一跳/出口侧延迟" "$DOWN_RTT")")
  LOSS_PCT=$(ask "loss percentage 丢包率百分比，例如 0 或 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "jitter ms 抖动" "$JITTER_MS")")
  infer_auto_topology
}

interactive_menu() {
  local choice key cursor=0 count=6 i answer
  local options=(
    "scene - 转发场景"
    "bandwidth/RTT/loss - 链路带宽、延迟、丢包抖动"
    "generate/apply - 生成配置并确认是否应用"
    "live sysctl - 查看系统已生效参数"
    "china-region-whitelist - 拉取中国地区白名单"
    "exit - 退出"
  )
  tput civis 2>/dev/null || true
  while true; do
    banner
    printf '%s主菜单%s\n' "$BOLD" "$RESET"
    printf '%s↑/↓ 或 j/k 选择，Enter 确认；也可按 1-6，q 退出%s\n\n' "$DIM" "$RESET"
    for ((i=0; i<count; i++)); do
      if (( i == cursor )); then
        printf '  %s> %d) %s%s\n' "$GREEN" $((i + 1)) "${options[$i]}" "$RESET"
      else
        printf '    %d) %s\n' $((i + 1)) "${options[$i]}"
      fi
    done
    printf '\n'
    hr
    if [[ "$DRAFT_DIRTY" == "yes" ]]; then
      show_summary
    else
      show_live_status_preview
    fi

    choice=""
    if read_key key; then
      case "$key" in
        $'\e[A'|$'\eOA'|k|K) cursor=$(((cursor + count - 1) % count)); continue ;;
        $'\e[B'|$'\eOB'|j|J) cursor=$(((cursor + 1) % count)); continue ;;
        ""|$'\r'|$'\n') choice=$((cursor + 1)) ;;
        [1-6]) choice="$key"; cursor=$((choice - 1)) ;;
        q|Q) exit 0 ;;
        *) continue ;;
      esac
    else
      prompt_read choice "请选择 [3]: " || true
      choice="${choice:-3}"
    fi

    case "$choice" in
      1) edit_scene; DRAFT_DIRTY="yes" ;;
      2) edit_link; DRAFT_DIRTY="yes" ;;
      3)
        if [[ "$DRAFT_DIRTY" == "yes" ]]; then
          break
        fi
        banner
        printf '当前主界面显示的是系统已生效参数，还没有待生效配置草案。\n'
        printf '建议先修改 1-2 项；网卡/RPS/TFO/busy_poll/会话表会在生成时自动判断。\n\n'
        answer=$(ask_yes_no "仍然使用脚本默认草案生成配置" "no")
        if [[ "$answer" == "yes" ]]; then
          DRAFT_DIRTY="yes"
          break
        fi
        ;;
      4) show_live_status ;;
      5) run_china_region_whitelist yes || true ;;
      6|q|Q) exit 0 ;;
      *) warn "无效选择"; pause_ui ;;
    esac
  done
}

linear_wizard() {
  SCENE=$(ask_choice "scene 转发场景" "$SCENE" front relay ix landing hybrid)
  apply_scene_defaults

  UP_MBPS=$(to_int "$(ask "upload/ingress Mbps 上行/入口带宽" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "download/egress Mbps 下行/出口带宽" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "upstream RTT ms 到上一跳/入口侧延迟" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "downstream RTT ms 到下一跳/出口侧延迟" "$DOWN_RTT")")
  LOSS_PCT=$(ask "loss percentage 丢包率百分比，例如 0 或 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "jitter ms 抖动" "$JITTER_MS")")

  HANDSHAKE="yes"
  TFO_GLOBAL="no"
  BUSY_MODE="auto"
  CONCURRENCY_MODE="auto"
  MANUAL_TCP_CAP_MB=0
  MANUAL_BDP_MULT=0
  BBR_KIND="unknown"
  TCP_CONNS_OVERRIDE=0
  UDP_SESSIONS_OVERRIDE=0
  CPS_OVERRIDE=0
  SERVICE_NAME=""
  infer_auto_topology
}

usage() {
  cat <<'USAGE'
Network BBR Optimizer / 中文 BBR 网络优化器 bbr.sh

交互式 Linux 网络优化脚本，默认面向转发/上网链路；支持前置入口、中继转发、专线/IX 转发、落地出口和混合网络节点。
固定策略为游戏低延迟 + UDP 实时优先 + 可控吞吐，不再询问容易误选的业务/目标/拓扑分支。

用法:
  bash bbr.sh             # 上下键可视化菜单，先生成配置，再确认是否应用
  bash bbr.sh --quick     # 精简问答模式，只问转发场景和链路参数
  bash bbr.sh --dry-run   # 只生成配置文件，不应用
  bash bbr.sh --apply     # 生成后默认询问应用
  bash bbr.sh --wgmimic-required  # 只生成/应用 WG/Mimic 必需 sysctl
  bash bbr.sh --china-whitelist   # 拉取并运行 china-region-whitelist
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
界面保留 BBR/TFO/RPS/nftables/conntrack/sysctl 等英文术语；stateful、多出口、IPv6 RA、RPS、TFO、busy_poll、会话表等自动项不再单独占主菜单。

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
    --wgmimic-required|--wgmimic-sysctl|--wg-mimic-sysctl) WGMIMIC_REQUIRED_ONLY="yes" ;;
    --china-whitelist|--china-region-whitelist|--whitelist) CHINA_WHITELIST_ONLY="yes" ;;
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
  local prompt="$1" default="$2" value normalized valid label label_name label_cn i
  shift 2
  local options=("$@")
  if has_tty; then
    if select_option "$prompt" "$default" "${options[@]}"; then
      return
    fi
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
      label_cn="${label_name#* }"
      if [[ "$label_cn" == "$label_name" ]]; then
        label_cn=""
      fi
      if [[ "$value" == "$valid" || "$value" == "$label" || "$value" == "$label_name" || "$value" == "$label_cn" ]]; then
        printf '%s' "$valid"
        return
      fi
    done
    normalized="$(normalize_scene_choice "$value")"
    for valid in "${options[@]}"; do
      if [[ "$normalized" == "$valid" ]]; then
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

module_available() {
  local module="$1" kernel path
  if command -v modinfo >/dev/null 2>&1 && modinfo "$module" >/dev/null 2>&1; then
    return 0
  fi
  kernel="$(uname -r 2>/dev/null || true)"
  [[ -n "$kernel" ]] || return 1
  for path in \
    "/lib/modules/$kernel/kernel" \
    "/usr/lib/modules/$kernel/kernel" \
    "/lib/modules/$kernel" \
    "/usr/lib/modules/$kernel"; do
    [[ -d "$path" ]] || continue
    if find "$path" -type f \( -name "${module}.ko" -o -name "${module}.ko.*" \) -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

try_load_module() {
  local module="$1"
  if command -v modprobe >/dev/null 2>&1 && is_root; then
    modprobe "$module" >/dev/null 2>&1 && return 0
  fi
  return 1
}

bbr_available_now() {
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

mem_kb() {
  awk -v key="$1" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' /proc/meminfo
}

detect_default_iface() {
  local iface
  command -v ip >/dev/null 2>&1 || return 0
  iface="$(ip route show default 2>/dev/null | awk '{
    for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }
  }')"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi
  ip -6 route show default 2>/dev/null | awk '{
    for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }
  }'
}

default_route_count() {
  local family="${1:-4}"
  command -v ip >/dev/null 2>&1 || { printf '0\n'; return 0; }
  if [[ "$family" == "6" ]]; then
    ip -6 route show default 2>/dev/null | awk 'END { print NR + 0 }'
  else
    ip route show default 2>/dev/null | awk 'END { print NR + 0 }'
  fi
}

policy_routing_present() {
  command -v ip >/dev/null 2>&1 || return 1
  ip rule show 2>/dev/null | awk '
    {
      line=$0
      sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "", line)
      if (line !~ /^from all lookup (local|main|default)$/) found=1
    }
    END { exit found ? 0 : 1 }
  '
}

ipv6_default_uses_ra() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 route show default 2>/dev/null | grep -qw 'proto ra'
}

iface_accepts_ra() {
  local value
  [[ -n "${DEFAULT_IFACE:-}" ]] || return 1
  value="$(read_sysctl "net.ipv6.conf.${DEFAULT_IFACE}.accept_ra" 0)"
  [[ "$value" == "1" || "$value" == "2" ]]
}

ip_forwarding_enabled_now() {
  [[ "$(read_sysctl net.ipv4.ip_forward 0)" == "1" ]] && return 0
  [[ "$(read_sysctl net.ipv6.conf.all.forwarding 0)" == "1" ]]
}

has_nat_or_tproxy_rules() {
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -Eiq '\b(masquerade|dnat|snat|redirect|tproxy)\b'; then
    return 0
  fi
  if command -v iptables-save >/dev/null 2>&1 && iptables-save 2>/dev/null | grep -Eiq '\b(MASQUERADE|DNAT|SNAT|REDIRECT|TPROXY)\b'; then
    return 0
  fi
  if command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save 2>/dev/null | grep -Eiq '\b(MASQUERADE|DNAT|SNAT|REDIRECT|TPROXY)\b'; then
    return 0
  fi
  return 1
}

has_tunnel_iface() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -o link show 2>/dev/null | awk -F': ' '
    $2 ~ /^(wg|tun|tap|tailscale|zt|nebula|mimic|phantun)/ { found=1 }
    END { exit found ? 0 : 1 }
  '
}

has_public_tcp_listener() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn 2>/dev/null | awk '
    function listen_port(addr, parts, n) {
      gsub(/^\[/, "", addr)
      gsub(/\]/, "", addr)
      n=split(addr, parts, ":")
      return parts[n]
    }
    function listen_host(addr, port) {
      gsub(/^\[/, "", addr)
      gsub(/\]/, "", addr)
      return substr(addr, 1, length(addr) - length(port) - 1)
    }
    {
      addr=$4
      port=listen_port(addr)
      host=listen_host(addr, port)
      if (host == "127.0.0.1" || host == "::1" || host == "localhost") next
      if (port ~ /^[0-9]+$/ && port != 22 && port != 2222 && port != 60022 && port !~ /^601[0-9]$/) {
        found=1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  '
}

infer_auto_topology() {
  local v4_defaults v6_defaults policy nat tunnel forwarding listener
  SCENE="$(normalize_scene_choice "${SCENE:-relay}")"
  v4_defaults="$(default_route_count 4)"
  v6_defaults="$(default_route_count 6)"
  policy="no"; policy_routing_present && policy="yes"
  nat="no"; has_nat_or_tproxy_rules && nat="yes"
  tunnel="no"; has_tunnel_iface && tunnel="yes"
  forwarding="no"; ip_forwarding_enabled_now && forwarding="yes"
  listener="no"; has_public_tcp_listener && listener="yes"

  if [[ "$ROLE" == "forwarding" ]]; then
    STATEFUL="yes"
    STATEFUL_REASON="角色=转发节点，自动按 NAT/TProxy/状态防火墙预留 conntrack"
    LANDING_ROUTES="no"
    LANDING_ROUTES_REASON="角色=转发节点，不使用落地路由开关"
  else
    SCENE="landing"
    if [[ "$nat" == "yes" || "$tunnel" == "yes" ]] || [[ "$forwarding" == "yes" && "$policy" == "yes" ]]; then
      LANDING_ROUTES="yes"
      LANDING_ROUTES_REASON="检测到 NAT/TProxy/隧道接口/策略路由转发痕迹，落地机同时按路由出口处理"
      STATEFUL="yes"
      STATEFUL_REASON="落地路由=是，需要 conntrack/NAT 状态容量"
    else
      LANDING_ROUTES="no"
      LANDING_ROUTES_REASON="未检测到 NAT/TProxy/隧道接口/策略路由转发痕迹，落地机按本机应用出口处理"
      STATEFUL="no"
      STATEFUL_REASON="落地路由=否，不主动放大 conntrack"
    fi
  fi

  if [[ "$ROLE" == "forwarding" ]]; then
    case "$SCENE" in
      hybrid)
        MULTIPATH="yes"
        MULTIPATH_REASON="混合网络节点同时存在本机终止和转发链路，关闭 rp_filter 避免回程包误丢"
        ;;
      front|ix|relay)
        MULTIPATH="yes"
        MULTIPATH_REASON="场景=$(scene_label)，默认可能存在专线/跨境/非对称回程，关闭 rp_filter"
        ;;
      *)
        if [[ "$policy" == "yes" || "$v4_defaults" -gt 1 || "$v6_defaults" -gt 1 || "$tunnel" == "yes" ]]; then
          MULTIPATH="yes"
          MULTIPATH_REASON="检测到多默认路由/策略路由/隧道接口，关闭 rp_filter"
        else
          MULTIPATH="no"
          MULTIPATH_REASON="普通转发且未检测到多出口或策略路由，使用 loose rp_filter"
        fi
        ;;
    esac
  elif [[ "$LANDING_ROUTES" == "yes" ]]; then
    MULTIPATH="yes"
    MULTIPATH_REASON="落地机承担隧道/NAT/路由出口，关闭 rp_filter 避免回程包误丢"
  elif [[ "$policy" == "yes" || "$v4_defaults" -gt 1 || "$v6_defaults" -gt 1 ]]; then
    MULTIPATH="yes"
    MULTIPATH_REASON="检测到多默认路由或策略路由，关闭 rp_filter"
  else
    MULTIPATH="no"
    MULTIPATH_REASON="未检测到多出口/策略路由，使用 loose rp_filter"
  fi

  if ipv6_default_uses_ra; then
    IPV6_RA="yes"
    IPV6_RA_REASON="IPv6 默认路由带 proto ra，说明依赖路由通告"
  elif iface_accepts_ra && [[ "$v6_defaults" -gt 0 ]]; then
    IPV6_RA="yes"
    IPV6_RA_REASON="默认网卡 accept_ra 已开启且存在 IPv6 默认路由"
  else
    IPV6_RA="no"
    IPV6_RA_REASON="未检测到依赖 RA 的 IPv6 默认路由"
  fi

  if [[ "$SCENE" == "hybrid" ]]; then
    LOCAL_TCP_TERMINATION="yes"
    LOCAL_TCP_TERMINATION_REASON="混合网络节点包含本机 TCP/UDP 终止，启用本机连接优化"
  elif [[ "$ROLE" == "landing" ]]; then
    LOCAL_TCP_TERMINATION="yes"
    LOCAL_TCP_TERMINATION_REASON="角色=落地出口，默认本机代理/隧道出口会终止连接"
  elif [[ "$listener" == "yes" ]]; then
    LOCAL_TCP_TERMINATION="yes"
    LOCAL_TCP_TERMINATION_REASON="检测到非 SSH 的公开 TCP 监听端口，启用本机 TFO 相关优化"
  else
    LOCAL_TCP_TERMINATION="no"
    LOCAL_TCP_TERMINATION_REASON="纯转发节点未检测到非 SSH 公开 TCP 服务，跳过 TFO"
  fi

  HANDSHAKE="yes"
  TFO_GLOBAL="no"
  BUSY_MODE="auto"
  CONCURRENCY_MODE="auto"
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

emit_adaptive_note() {
  local key="$1" reason="$2"
  printf '# 保留系统自适应，不写入: %s (%s)\n' "$key" "$reason" >> "$SYSCTL_OUT"
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

disable_legacy_initcwnd_enforcer() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [[ -e /etc/systemd/system/initcwnd-enforcer.timer || -e /etc/systemd/system/initcwnd-enforcer.service || -e /usr/local/bin/enforce-initcwnd.sh ]]; then
    warn "发现旧版 initcwnd-enforcer，已停用；新版默认交给内核自适应，不再强写 initcwnd/initrwnd。"
    systemctl disable --now initcwnd-enforcer.timer >/dev/null 2>&1 || true
    systemctl reset-failed initcwnd-enforcer.service initcwnd-enforcer.timer >/dev/null 2>&1 || true
  fi
}

sync_conntrack_hashsize_live() {
  local path="/sys/module/nf_conntrack/parameters/hashsize" current
  [[ "$CT_NEEDED" == "yes" ]] || return 0
  [[ -e "$path" ]] || return 0
  current="$(cat "$path" 2>/dev/null || true)"
  [[ "$current" == "$NF_CONNTRACK_BUCKETS" ]] && return 0
  if [[ -w "$path" ]]; then
    if printf '%s' "$NF_CONNTRACK_BUCKETS" > "$path" 2>/dev/null; then
      return 0
    fi
  fi
  warn "nf_conntrack hashsize 当前运行值未能同步到 $NF_CONNTRACK_BUCKETS，重启后会按 /etc/modprobe.d/nf_conntrack.conf 生效。"
}

print_final_sysctl_status() {
  printf '\n最终生效检查:\n'
  print_live_sysctl net.ipv4.tcp_available_congestion_control
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
restore_or_remove /etc/modules-load.d/99-network-optimize.conf
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
echo "回滚文件已恢复。conntrack hashsize、路由或网卡运行时状态可能需要重启网络或重启系统才会完全回退。"
EOF
  chmod +x "$rollback"
}

emit_wgmimic_required_sysctl() {
  local file="$1" key="$2" value="$3"
  if sysctl_exists "$key"; then
    printf '%s = %s\n' "$key" "$value" >> "$file"
  else
    printf '# 已跳过，当前内核缺少该参数: %s = %s\n' "$key" "$value" >> "$file"
  fi
}

write_wgmimic_required_sysctl_file() {
  local file="$1" default_iface="${DEFAULT_IFACE:-}" preserve_ra="no"
  [[ -n "$default_iface" ]] || default_iface="$(detect_default_iface)"
  if [[ -n "$default_iface" ]]; then
    DEFAULT_IFACE="$default_iface"
    if ipv6_default_uses_ra || iface_accepts_ra; then
      preserve_ra="yes"
    fi
  fi
  : > "$file"
  {
    printf '# 由 bbr.sh %s 生成，时间: %s\n' "$VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# WG/Mimic 必需 sysctl：只保证隧道路由/转发工作，不调整 BBR、RPS、队列、conntrack 容量。\n\n'
  } >> "$file"

  emit_wgmimic_required_sysctl "$file" net.ipv4.ip_forward 1
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.all.forwarding 1
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.default.forwarding 1
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.all.rp_filter 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.default.rp_filter 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.all.accept_source_route 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.default.accept_source_route 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.all.send_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.default.send_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.all.accept_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv4.conf.default.accept_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.all.accept_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.default.accept_redirects 0
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.all.accept_source_route 0
  emit_wgmimic_required_sysctl "$file" net.ipv6.conf.default.accept_source_route 0
  if [[ "$preserve_ra" == "yes" ]]; then
    printf '# 默认 IPv6 路由依赖 RA；开启 IPv6 forwarding 时保留 %s 接收 RA。\n' "$default_iface" >> "$file"
    emit_wgmimic_required_sysctl "$file" "net.ipv6.conf.${default_iface}.accept_ra" 2
  fi
}

apply_wgmimic_required_sysctl() {
  local out_dir sysctl_out backup_dir do_apply
  need_linux
  if [[ -z "${STATE_DIR:-}" ]]; then
    STATE_DIR="$(default_state_dir)"
  fi
  if [[ -z "${TS:-}" ]]; then
    TS="$(date +%Y%m%d-%H%M%S)"
  fi
  if [[ -n "${OUT_DIR:-}" ]]; then
    out_dir="$OUT_DIR"
  else
    out_dir="$STATE_DIR/runs/${TS}-wgmimic-required"
  fi
  mkdir -p "$out_dir" "$STATE_DIR" 2>/dev/null || true
  ln -sfn "$out_dir" "$STATE_DIR/latest" 2>/dev/null || true
  sysctl_out="$out_dir/98-wgmimic-required.conf"
  write_wgmimic_required_sysctl_file "$sysctl_out"

  printf '\n已生成 WG/Mimic 必需 sysctl：%s\n' "$sysctl_out"
  sed -n '1,120p' "$sysctl_out"

  if [[ "$APPLY_MODE" == "no" ]]; then
    log "dry-run 模式：未应用。"
    return 0
  fi
  if ! is_root; then
    warn "当前不是 root，只生成配置文件；如需应用请使用 sudo 重新运行。"
    return 0
  fi

  if [[ "$APPLY_MODE" == "yes" ]]; then
    do_apply="yes"
  else
    do_apply=$(ask_yes_no "现在应用 WG/Mimic 必需 sysctl 吗" "yes")
  fi
  [[ "$do_apply" == "yes" ]] || { log "未应用配置。"; return 0; }

  backup_dir="$STATE_DIR/backups/${TS}-wgmimic-required"
  mkdir -p "$backup_dir"
  ln -sfn "$backup_dir" "$STATE_DIR/latest-backup" 2>/dev/null || true
  install_file "$sysctl_out" /etc/sysctl.d/98-wgmimic-required.conf 0644 "$backup_dir"
  sysctl --system
  apply_generated_sysctl_live "$sysctl_out"

  printf '\nWG/Mimic 必需 sysctl 已应用。关键状态：\n'
  print_live_sysctl net.ipv4.ip_forward
  print_live_sysctl net.ipv6.conf.all.forwarding
  print_live_sysctl net.ipv4.conf.all.rp_filter
  print_live_sysctl net.ipv4.conf.default.rp_filter
  printf '备份目录: %s\n' "$backup_dir"
}

need_linux

TS="$(date +%Y%m%d-%H%M%S)"
if [[ "$CLEAN_OUTPUTS" == "yes" ]]; then
  clean_legacy_outputs
  exit 0
fi

STATE_DIR="$(default_state_dir)"

if [[ "$WGMIMIC_REQUIRED_ONLY" == "yes" ]]; then
  apply_wgmimic_required_sysctl
  exit 0
fi

if [[ "$CHINA_WHITELIST_ONLY" == "yes" ]]; then
  run_china_region_whitelist no
  exit $?
fi

MEM_TOTAL_KB=$(mem_kb MemTotal)
MEM_AVAIL_KB=$(mem_kb MemAvailable)
if (( MEM_AVAIL_KB <= 0 )); then MEM_AVAIL_KB="$MEM_TOTAL_KB"; fi
CPU_COUNT=$(cpu_count)
DEFAULT_IFACE=$(detect_default_iface)
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"
RX_QUEUES=$(count_queues "$DEFAULT_IFACE" rx)
TX_QUEUES=$(count_queues "$DEFAULT_IFACE" tx)

ROLE="forwarding"
SCENE="relay"
TARGET="speed"
BUSINESS="udp_game"
CONCURRENCY_MODE="auto"
STATEFUL="auto"
LANDING_ROUTES="auto"
IPV6_RA="auto"
MULTIPATH="auto"
HANDSHAKE="yes"
TFO_GLOBAL="no"
LOCAL_TCP_TERMINATION="auto"
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
STATEFUL_REASON="等待自动推断"
LANDING_ROUTES_REASON="等待自动推断"
MULTIPATH_REASON="等待自动推断"
IPV6_RA_REASON="等待自动推断"
LOCAL_TCP_TERMINATION_REASON="等待自动推断"

if [[ "$UI_MODE" == "menu" ]] && has_tty; then
  interactive_menu
else
  linear_wizard
fi
infer_auto_topology

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$STATE_DIR/runs/$TS"
  OUT_DIR_AUTO="yes"
fi
mkdir -p "$OUT_DIR"
SYSCTL_OUT="$OUT_DIR/99-network-optimize.conf"
LIMITS_OUT="$OUT_DIR/99-network-optimize-limits.conf"
SYSTEMD_OUT="$OUT_DIR/99-network-optimize-system.conf"
MODPROBE_OUT="$OUT_DIR/nf_conntrack.conf"
MODULES_LOAD_OUT="$OUT_DIR/99-network-optimize-modules.conf"
ROUTE_OUT="$OUT_DIR/network-optimize-route.sh"
NIC_OUT="$OUT_DIR/network-optimize-nic.sh"
REPORT_OUT="$OUT_DIR/report.txt"

mkdir -p "$STATE_DIR" 2>/dev/null || true
ln -sfn "$OUT_DIR" "$STATE_DIR/latest" 2>/dev/null || true

printf 'Network BBR Optimizer / 中文 BBR 网络优化器 bbr.sh %s\n' "$VERSION"
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
    TCP_CONNS=$((TCP_CONNS / 2))
    UDP_SESSIONS=$((UDP_SESSIONS * 3 / 4))
    CPS=$((CPS / 2))
    MEM_PCT=$((MEM_PCT - 24))
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
      UDP_SESSIONS=$((UDP_SESSIONS * 12 / 10))
      MEM_PCT=$((MEM_PCT + 6))
      ;;
    hybrid)
      TCP_CONNS=$((TCP_CONNS * 13 / 10))
      UDP_SESSIONS=$((UDP_SESSIONS * 12 / 10))
      CPS=$((CPS * 14 / 10))
      MEM_PCT=$((MEM_PCT + 8))
      ;;
  esac
fi

CONCURRENCY_EFFECTIVE="$CONCURRENCY_MODE"
LINK_MBPS_FOR_CONCURRENCY=$(max "$UP_MBPS" "$DOWN_MBPS")
if [[ "$CONCURRENCY_EFFECTIVE" == "auto" ]]; then
  CONCURRENCY_EFFECTIVE="balanced"
  if [[ "$BUSINESS" != "udp_game" && "$ROLE" == "forwarding" && "$STATEFUL" == "yes" ]] && [[ "$SCENE" == "front" || "$SCENE" == "ix" || "$SCENE" == "relay" || "$SCENE" == "hybrid" ]] && (( LINK_MBPS_FOR_CONCURRENCY >= 100 )) && (( MEM_TOTAL_KB >= 2048 * 1024 )); then
    CONCURRENCY_EFFECTIVE="high"
  fi
  if [[ "$BUSINESS" != "udp_game" && "$ROLE" == "forwarding" && "$STATEFUL" == "yes" && "$SCENE" == "ix" ]] \
     && (( LINK_MBPS_FOR_CONCURRENCY >= 1000 )) \
     && (( MEM_TOTAL_KB >= 8192 * 1024 )) \
     && (( CPU_COUNT >= 4 )) \
     && (( RX_QUEUES >= 4 )); then
    CONCURRENCY_EFFECTIVE="extreme"
  fi
fi

case "$CONCURRENCY_EFFECTIVE" in
  high)
    TCP_CONNS=$((TCP_CONNS * 13 / 10))
    UDP_SESSIONS=$((UDP_SESSIONS * 15 / 10))
    CPS=$((CPS * 13 / 10))
    MEM_PCT=$((MEM_PCT + 4))
    ;;
  extreme)
    TCP_CONNS=$((TCP_CONNS * 16 / 10))
    UDP_SESSIONS=$((UDP_SESSIONS * 2))
    CPS=$((CPS * 16 / 10))
    MEM_PCT=$((MEM_PCT + 8))
    ;;
esac

MEM_PCT=$((MEM_PCT + 14))
if [[ "$BUSINESS" == "udp_game" ]]; then
  MEM_PCT=$(clamp "$MEM_PCT" 20 48)
else
  MEM_PCT=$(clamp "$MEM_PCT" 35 78)
fi
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

if [[ "$BUSINESS" == "udp_game" ]]; then
  if [[ "$BBR_KIND" == "bbr3" ]]; then
    BDP_MULT=3
  else
    BDP_MULT=4
  fi
elif [[ "$BBR_KIND" == "bbr3" ]]; then
  BDP_MULT=8
else
  BDP_MULT=10
fi
if [[ "$BUSINESS" != "udp_game" ]]; then
  BDP_MULT=$((BDP_MULT + 2))
  [[ "$BUSINESS" == "mixed" ]] && BDP_MULT=$((BDP_MULT + 1))
  (( LOSS_BP >= 100 )) && BDP_MULT=$((BDP_MULT + 1))
  (( LOSS_BP >= 300 )) && BDP_MULT=$((BDP_MULT + 1))
elif (( LOSS_BP >= 100 )); then
  BDP_MULT=$((BDP_MULT + 1))
fi
JITTER_GUARD="no"
if (( JITTER_MS > MAXRTT / 2 + 1 )); then
  [[ "$BUSINESS" != "udp_game" ]] && BDP_MULT=$((BDP_MULT + 1))
  JITTER_GUARD="yes"
fi
if [[ "$BUSINESS" != "udp_game" && "$SCENE" == "ix" ]] && (( LOSS_BP < 100 )); then
  BDP_MULT=$((BDP_MULT + 2))
fi
if (( MANUAL_BDP_MULT > 0 )); then
  BDP_MULT="$MANUAL_BDP_MULT"
fi
if [[ "$BUSINESS" == "udp_game" ]]; then
  BDP_MULT=$(clamp "$BDP_MULT" 2 6)
else
  BDP_MULT=$(clamp "$BDP_MULT" 2 16)
fi
if (( LOSS_BP >= 100 )) || [[ "$JITTER_GUARD" == "yes" ]] || [[ "$BUSINESS" == "udp_game" ]]; then
  QUEUE_JITTER_GUARD="yes"
  if [[ "$BUSINESS" == "udp_game" ]]; then
    BDP_MULT=$(min "$BDP_MULT" 6)
    NETDEV_BACKLOG_CAP=65536
    NETDEV_BUDGET_USECS_CAP=10000
  else
    BDP_MULT=$(min "$BDP_MULT" 12)
    NETDEV_BACKLOG_CAP=524288
    NETDEV_BUDGET_USECS_CAP=10000
  fi
else
  QUEUE_JITTER_GUARD="no"
  NETDEV_BACKLOG_CAP=1048576
  NETDEV_BUDGET_USECS_CAP=12000
fi

NETDEV_RESOURCE_CAP=131072
if (( MBW >= 300 )) || [[ "$CONCURRENCY_EFFECTIVE" == "high" || "$CONCURRENCY_EFFECTIVE" == "extreme" ]]; then
  NETDEV_RESOURCE_CAP=262144
fi
if (( CPU_COUNT >= 4 && RX_QUEUES >= 4 && MBW >= 1000 )); then
  NETDEV_RESOURCE_CAP=524288
fi
if [[ "$CONCURRENCY_EFFECTIVE" == "extreme" ]] && (( CPU_COUNT >= 8 && RX_QUEUES >= 4 && MBW >= 2000 )); then
  NETDEV_RESOURCE_CAP=1048576
fi
if [[ "$QUEUE_JITTER_GUARD" == "yes" ]]; then
  NETDEV_RESOURCE_CAP=$(min "$NETDEV_RESOURCE_CAP" 262144)
fi
if [[ "$BUSINESS" == "udp_game" ]]; then
  NETDEV_RESOURCE_CAP=$(min "$NETDEV_RESOURCE_CAP" 65536)
  NETDEV_BACKLOG_CAP=$(min "$NETDEV_BACKLOG_CAP" 65536)
fi
NETDEV_BACKLOG_CAP=$(min "$NETDEV_BACKLOG_CAP" "$NETDEV_RESOURCE_CAP")

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
TCP_FLOOR=$((16 * MIB))
if [[ "$ROLE" == "landing" && "$LANDING_ROUTES" != "yes" ]]; then
  TCP_FLOOR=$((8 * MIB))
fi
if [[ "$BUSINESS" == "udp_game" ]]; then
  TCP_FLOOR=$((8 * MIB))
fi
if (( MEM_TOTAL_KB < 768 * 1024 )); then
  TCP_FLOOR=$((8 * MIB))
fi

if (( MANUAL_TCP_CAP_MB > 0 )); then
  HARD_CAP=$((MANUAL_TCP_CAP_MB * MIB))
else
  HARD_CAP=$(min "$AUTO_TCP_CAP" "$MEM_CAP")
  if [[ "$BUSINESS" == "udp_game" ]]; then
    HARD_CAP=$(min "$HARD_CAP" $((32 * MIB)))
  fi
fi
HARD_CAP=$(max "$HARD_CAP" "$TCP_FLOOR")
DESIRED=$((BDP * BDP_MULT))
TCP_MAX=$(round_up_mib "$DESIRED")
TCP_MAX=$(max "$TCP_MAX" "$TCP_FLOOR")
TCP_MAX=$(min "$TCP_MAX" "$HARD_CAP")
TCP_MAX=$(max "$TCP_MAX" "$TCP_FLOOR")

read -r TCP_RMEM_MIN TCP_RMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_rmem '4096 87380 6291456')"
read -r TCP_WMEM_MIN TCP_WMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_wmem '4096 65536 4194304')"

TFO_VALUE=""
if [[ "$HANDSHAKE" == "yes" ]]; then
  if [[ "$LOCAL_TCP_TERMINATION" == "yes" ]]; then
    TFO_VALUE=3
  else
    TFO_VALUE=""
  fi
  if [[ "$TFO_GLOBAL" == "yes" && -n "$TFO_VALUE" ]]; then
    TFO_VALUE=$((TFO_VALUE | 1024))
  fi
fi

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
if [[ "$TARGET" == "throughput" || "$UDP_SESSIONS" -gt 50000 ]]; then UDP_MIN=$(max "$UDP_MIN" 8192); fi
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

TCP_LIMIT_FACTOR=6
[[ "$TARGET" == "throughput" ]] && TCP_LIMIT_FACTOR=8
if [[ "$SCENE" == "ix" && "$LOSS_BP" -lt 50 ]]; then TCP_LIMIT_FACTOR=8; fi
if (( LOSS_BP >= 100 )) || [[ "$QUEUE_JITTER_GUARD" == "yes" ]]; then TCP_LIMIT_FACTOR=4; fi
LIMIT_LOWER="$MIB"
LIMIT_UPPER=$(clamp $((TCP_MAX / 2)) $((4 * MIB)) $((64 * MIB)))
if [[ "$BUSINESS" == "udp_game" ]]; then
  TCP_LIMIT_FACTOR=1
  LIMIT_LOWER=$((512 * 1024))
  LIMIT_UPPER=$(clamp $((TCP_MAX / 4)) $((4 * MIB)) $((8 * MIB)))
fi
TCP_LIMIT=$(clamp $((BDP * TCP_LIMIT_FACTOR)) "$LIMIT_LOWER" "$LIMIT_UPPER")

SOMAXCONN=$(pow2ceil "$(clamp $((CPS * 4 + TCP_CONNS / 16)) 4096 1048576)")
SYN_BACKLOG=$(pow2ceil "$(clamp $((CPS * 8 + TCP_CONNS / 8)) 8192 1048576)")
FLOW_LIMIT=$(pow2ceil "$(clamp $((TCP_CONNS / 16 + UDP_SESSIONS / 8 + CPS * 2)) 4096 1048576)")
NOFILE=$(pow2ceil "$(clamp $(((TCP_CONNS + UDP_SESSIONS + CPS * 10) * 2 + 4096)) 65536 8388608)")
FS_FILE_MAX=$(pow2ceil "$(clamp $((NOFILE * 2)) 1048576 16777216)")
TW_BUCKETS=$(pow2ceil "$(clamp $((TCP_CONNS / 2 + CPS * 60)) 262144 4194304)")
FIN_TIMEOUT=15
[[ "$BUSINESS" == "web" ]] && FIN_TIMEOUT=10
[[ "$BUSINESS" == "mixed" && "$CPS" -gt 8000 ]] && FIN_TIMEOUT=10

NETDEV_RAW=$((MBW * 16 + CPS * 8 + UDP_SESSIONS / 8))
NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$SCENE" == "ix" ]] && NETDEV_RAW=$((NETDEV_RAW * 2))
[[ "$TARGET" == "throughput" ]] && NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$BUSINESS" == "mixed" ]] && NETDEV_RAW=$((NETDEV_RAW + UDP_SESSIONS / 6))
[[ "$BUSINESS" == "udp_game" ]] && NETDEV_RAW=$((MBW * 8 + CPS * 4 + UDP_SESSIONS / 16))
NETDEV_BACKLOG=$(pow2ceil "$(clamp "$NETDEV_RAW" 4096 "$NETDEV_BACKLOG_CAP")")

CT_NEEDED="no"
if [[ "$ROLE" == "forwarding" && "$STATEFUL" == "yes" ]]; then CT_NEEDED="yes"; fi
if [[ "$ROLE" == "landing" && "$LANDING_ROUTES" == "yes" ]]; then CT_NEEDED="yes"; fi
CT_RAW=$((TCP_CONNS + UDP_SESSIONS * 2 + CPS * 90))
[[ "$SCENE" == "ix" ]] && CT_RAW=$((CT_RAW * 15 / 10))
[[ "$TARGET" == "throughput" ]] && CT_RAW=$((CT_RAW * 125 / 100))
[[ "$BUSINESS" == "mixed" ]] && CT_RAW=$((CT_RAW + UDP_SESSIONS / 2))
[[ "$BUSINESS" == "udp_game" ]] && CT_RAW=$((CT_RAW + UDP_SESSIONS / 4))
CT_MEM_CAP=$((MEM_TOTAL_BYTES * MEM_PCT / 100 / 512))
CT_UPPER=$(min 16777216 "$(max 131072 "$CT_MEM_CAP")")
CT_RESOURCE_CAP=1048576
case "$CONCURRENCY_EFFECTIVE" in
  high)
    CT_RESOURCE_CAP=2097152
    if (( CPU_COUNT >= 4 && RX_QUEUES >= 2 && MBW >= 500 )); then
      CT_RESOURCE_CAP=4194304
    fi
    ;;
  extreme)
    CT_RESOURCE_CAP=8388608
    if (( CPU_COUNT >= 8 && RX_QUEUES >= 4 && MBW >= 2000 && MEM_TOTAL_KB >= 16384 * 1024 )); then
      CT_RESOURCE_CAP=16777216
    fi
    ;;
esac
CT_UPPER=$(min "$CT_UPPER" "$CT_RESOURCE_CAP")
NF_CONNTRACK_MAX=$(clamp "$(pow2ceil "$CT_RAW")" 131072 "$CT_UPPER")
NF_CONNTRACK_HASH_RAW=$(ceil_div "$NF_CONNTRACK_MAX" 8)
NF_CONNTRACK_BUCKETS=$(pow2ceil "$(clamp "$NF_CONNTRACK_HASH_RAW" 32768 16777216)")

CT_TCP_EST=900
[[ "$BUSINESS" == "web" ]] && CT_TCP_EST=1200
(( TCP_CONNS > 500000 )) && CT_TCP_EST=600
CT_UDP=45
[[ "$BUSINESS" == "mixed" ]] && CT_UDP=35
[[ "$BUSINESS" == "udp_game" ]] && CT_UDP=30
CT_UDP_STREAM=180

RX_QUEUES=$(max "$RX_QUEUES" 1)
NETDEV_BUDGET=$(clamp $((RX_QUEUES * 800)) 1600 20000)
NETDEV_BUDGET_USECS=$(clamp 10000 1 "$NETDEV_BUDGET_USECS_CAP")
[[ "$TARGET" == "throughput" ]] && NETDEV_BUDGET_USECS=$(clamp 12000 1 "$NETDEV_BUDGET_USECS_CAP")

RPS_ENABLE="no"
if (( CPU_COUNT >= 2 )); then
  if [[ "$SCENE" == "hybrid" || "$ROLE" == "landing" ]]; then
    if (( RX_QUEUES <= CPU_COUNT )); then
      RPS_ENABLE="yes"
    fi
  elif [[ "$BUSINESS" == "udp_game" ]]; then
    if (( RX_QUEUES < CPU_COUNT && CPU_COUNT >= 4 && MBW >= 1000 )); then
      RPS_ENABLE="yes"
    fi
  elif (( RX_QUEUES < CPU_COUNT )); then
    RPS_ENABLE="yes"
  fi
fi
RPS_ENTRIES=$(clamp "$FLOW_LIMIT" 32768 2097152)
RPS_FLOW_CNT=$(clamp $((RPS_ENTRIES / RX_QUEUES)) 1024 65536)
RPS_CPUS=$(cpumask_all "$CPU_COUNT")

TCP_NOTSENT_LOWAT=""
if [[ "$LOCAL_TCP_TERMINATION" == "yes" ]] && [[ "$SCENE" == "hybrid" || "$ROLE" == "landing" ]]; then
  if (( MEM_TOTAL_KB < 1024 * 1024 )); then
    TCP_NOTSENT_LOWAT=$(clamp $((TCP_LIMIT / 2)) $((512 * 1024)) "$MIB")
  elif (( MEM_TOTAL_KB < 2048 * 1024 )); then
    TCP_NOTSENT_LOWAT=$(clamp $((TCP_LIMIT / 2)) "$MIB" $((2 * MIB)))
  fi
fi

TCP_SLOW_START_AFTER_IDLE=""
if [[ "$LOCAL_TCP_TERMINATION" == "yes" && "$BUSINESS" != "udp_game" ]]; then
  TCP_SLOW_START_AFTER_IDLE=0
fi

TCP_NO_METRICS_SAVE=""
if [[ "$MULTIPATH" == "yes" ]] && [[ "$SCENE" == "front" || "$SCENE" == "hybrid" || "$LANDING_ROUTES" == "yes" ]]; then
  TCP_NO_METRICS_SAVE=1
fi

RP_FILTER=2
[[ "$MULTIPATH" == "yes" ]] && RP_FILTER=0

: > "$SYSCTL_OUT"
{
  printf '# 由 bbr.sh %s 生成，时间: %s\n' "$VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# 角色=%s 场景=%s 目标=%s 业务=%s\n\n' "$(role_label)" "$(scene_label)" "$(target_label)" "$(business_label)"
} >> "$SYSCTL_OUT"

# ip_forward 从 0 切到 1 时会按路由器画像重置 IPv4 sysctl；必须先写转发开关，再写 TCP/队列细项。
if [[ "$ROLE" == "forwarding" || "$LANDING_ROUTES" == "yes" ]]; then
  emit_sysctl net.ipv4.ip_forward 1
  emit_sysctl net.ipv6.conf.all.forwarding 1
  emit_sysctl net.ipv6.conf.default.forwarding 1
  emit_sysctl net.ipv4.conf.all.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.default.rp_filter "$RP_FILTER"
  emit_sysctl "net.ipv4.conf.${DEFAULT_IFACE}.rp_filter" "$RP_FILTER"
  emit_sysctl net.ipv4.conf.all.accept_source_route 0
  emit_sysctl net.ipv4.conf.default.accept_source_route 0
  emit_sysctl "net.ipv4.conf.${DEFAULT_IFACE}.accept_source_route" 0
  emit_sysctl net.ipv4.conf.all.send_redirects 0
  emit_sysctl net.ipv4.conf.default.send_redirects 0
  emit_sysctl "net.ipv4.conf.${DEFAULT_IFACE}.send_redirects" 0
  emit_sysctl net.ipv4.conf.all.accept_redirects 0
  emit_sysctl net.ipv4.conf.default.accept_redirects 0
  emit_sysctl "net.ipv4.conf.${DEFAULT_IFACE}.accept_redirects" 0
  emit_sysctl net.ipv6.conf.all.accept_redirects 0
  emit_sysctl net.ipv6.conf.default.accept_redirects 0
  emit_sysctl "net.ipv6.conf.${DEFAULT_IFACE}.accept_redirects" 0
  emit_sysctl net.ipv6.conf.all.accept_source_route 0
  emit_sysctl net.ipv6.conf.default.accept_source_route 0
  emit_sysctl "net.ipv6.conf.${DEFAULT_IFACE}.accept_source_route" 0
  if [[ "$IPV6_RA" == "yes" ]]; then
    printf '# IPv6 默认路由依赖 %s 的 RA：开启 forwarding 时自动保留该接口接收 RA。\n' "$DEFAULT_IFACE" >> "$SYSCTL_OUT"
    emit_sysctl "net.ipv6.conf.${DEFAULT_IFACE}.accept_ra" 2
  fi
else
  printf '# 落地节点未启用 NAT/路由：不写 ip_forward/rp_filter，保留系统或其他服务自己的网络策略。\n' >> "$SYSCTL_OUT"
  emit_adaptive_note net.ipv4.ip_forward "纯落地机不主动覆盖"
  emit_adaptive_note net.ipv6.conf.all.forwarding "纯落地机不主动覆盖"
  emit_adaptive_note net.ipv6.conf.default.forwarding "纯落地机不主动覆盖"
  emit_adaptive_note net.ipv4.conf.all.rp_filter "纯落地机不主动覆盖"
  emit_adaptive_note net.ipv4.conf.default.rp_filter "纯落地机不主动覆盖"
fi

try_load_module tcp_bbr || true
try_load_module sch_fq || true

emit_sysctl net.core.default_qdisc fq
if bbr_available_now || module_available tcp_bbr; then
  emit_sysctl net.ipv4.tcp_congestion_control bbr
else
  printf '# 已跳过: 当前内核没有暴露 bbr，且未发现 tcp_bbr 模块\n' >> "$SYSCTL_OUT"
fi
emit_sysctl fs.file-max "$FS_FILE_MAX"
emit_sysctl net.core.rmem_max "$TCP_MAX"
emit_sysctl net.core.wmem_max "$TCP_MAX"
emit_adaptive_note net.core.rmem_default "保留发行版/应用默认 socket 缓冲，避免所有连接被固定放大"
emit_adaptive_note net.core.wmem_default "保留发行版/应用默认 socket 缓冲，避免所有连接被固定放大"
emit_sysctl net.ipv4.tcp_rmem "$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_MAX"
emit_sysctl net.ipv4.tcp_wmem "$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_MAX"
emit_adaptive_note net.ipv4.tcp_window_scaling "TCP 能力由内核和对端协商"
emit_adaptive_note net.ipv4.tcp_timestamps "TCP 能力由内核和对端协商"
emit_adaptive_note net.ipv4.tcp_sack "TCP 能力由内核和对端协商"
emit_adaptive_note net.ipv4.tcp_dsack "TCP 能力由内核和对端协商"
emit_adaptive_note net.ipv4.tcp_moderate_rcvbuf "TCP 接收缓冲由内核自动调节"
emit_sysctl net.core.optmem_max "$OPTMEM"
if [[ -n "$TCP_NOTSENT_LOWAT" ]]; then
  emit_sysctl net.ipv4.tcp_notsent_lowat "$TCP_NOTSENT_LOWAT"
else
  emit_adaptive_note net.ipv4.tcp_notsent_lowat "未触发小内存本机终止/落地条件，保留应用/内核发送队列自适应"
fi
if [[ -n "$TCP_SLOW_START_AFTER_IDLE" ]]; then
  emit_sysctl net.ipv4.tcp_slow_start_after_idle "$TCP_SLOW_START_AFTER_IDLE"
else
  emit_adaptive_note net.ipv4.tcp_slow_start_after_idle "未触发本机 TCP 终止条件，保留内核默认 idle 后慢启动"
fi
emit_adaptive_note net.ipv4.tcp_min_rtt_wlen "BBR/内核按路径学习 RTT，不固定观察窗口"
emit_adaptive_note net.ipv4.tcp_max_reordering "重排容忍由内核按路径学习，不固定全局阈值"
emit_adaptive_note net.ipv4.tcp_ecn "ECN 由内核默认策略和对端协商，不全局强制开关"
if [[ -n "$TFO_VALUE" ]]; then
  emit_sysctl net.ipv4.tcp_fastopen "$TFO_VALUE"
  emit_adaptive_note net.ipv4.tcp_fastopen_blackhole_timeout_sec "保留内核默认黑洞检测退避"
else
  printf '# 已跳过: 纯内核转发且本机不终止 TCP 时，tcp_fastopen 对被转发连接没有实际帮助\n' >> "$SYSCTL_OUT"
  emit_adaptive_note net.ipv4.tcp_fastopen "不再为纯转发机硬写 0，保留系统/其他服务自己的设置"
fi
emit_sysctl net.ipv4.tcp_mtu_probing 1
emit_sysctl net.ipv4.tcp_rfc1337 1
if [[ -n "$TCP_NO_METRICS_SAVE" ]]; then
  emit_sysctl net.ipv4.tcp_no_metrics_save "$TCP_NO_METRICS_SAVE"
else
  emit_adaptive_note net.ipv4.tcp_no_metrics_save "未触发前置/混合/落地路由多路径条件，保留内核目的地 metrics 学习能力"
fi
emit_sysctl net.ipv4.tcp_tw_reuse 1
emit_sysctl net.ipv4.tcp_max_tw_buckets "$TW_BUCKETS"
emit_sysctl net.ipv4.tcp_fin_timeout "$FIN_TIMEOUT"
emit_sysctl net.ipv4.tcp_syncookies 1
emit_adaptive_note net.ipv4.tcp_keepalive_time "keepalive 更适合由应用或发行版默认控制"
emit_adaptive_note net.ipv4.tcp_keepalive_intvl "keepalive 更适合由应用或发行版默认控制"
emit_adaptive_note net.ipv4.tcp_keepalive_probes "keepalive 更适合由应用或发行版默认控制"
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

if [[ "$CT_NEEDED" == "yes" ]]; then
  emit_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_MAX"
  emit_sysctl net.netfilter.nf_conntrack_tcp_timeout_established "$CT_TCP_EST"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout "$CT_UDP"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout_stream "$CT_UDP_STREAM"
else
  printf '# 当前角色不需要本脚本放大 conntrack：不写 nf_conntrack_max，交给内核/防火墙配置自适应。\n' >> "$SYSCTL_OUT"
  emit_adaptive_note net.netfilter.nf_conntrack_max "当前不是状态转发/NAT 出口"
fi

if [[ -n "$BUSY_POLL" ]]; then
  emit_sysctl net.core.busy_poll "$BUSY_POLL"
  emit_sysctl net.core.busy_read "$BUSY_POLL"
else
  emit_adaptive_note net.core.busy_poll "当前场景不需要低延迟轮询，不硬写 0 覆盖系统/其他服务"
  emit_adaptive_note net.core.busy_read "当前场景不需要低延迟轮询，不硬写 0 覆盖系统/其他服务"
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

cat > "$MODULES_LOAD_OUT" <<'EOF'
# Network BBR Optimizer: load TCP BBR and fq qdisc modules before sysctl applies.
tcp_bbr
sch_fq
EOF

cat > "$ROUTE_OUT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
clean_route_init() {
  local family="$1" line clean
  local -a route_parts
  if [[ "$family" == "4" ]]; then
    ip route show default 2>/dev/null
  else
    ip -6 route show default 2>/dev/null
  fi | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == *" initcwnd "* || "$line" == *" initrwnd "* ]] || continue
    clean=$(printf '%s' "$line" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')
    read -r -a route_parts <<< "$clean"
    if [[ "$family" == "4" ]]; then
      ip route replace "${route_parts[@]}" || true
    else
      ip -6 route replace "${route_parts[@]}" || true
    fi
  done
}
clean_route_init 4
clean_route_init 6
EOF
chmod +x "$ROUTE_OUT"

cat > "$NIC_OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFACE="${DEFAULT_IFACE}"
RPS_ENABLE="$RPS_ENABLE"
RPS_CPUS="$RPS_CPUS"
RPS_FLOW_CNT="$RPS_FLOW_CNT"
if [[ -d "/sys/class/net/\$IFACE" ]]; then
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
生成时间_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
脚本版本=$VERSION

[输入和选择]
默认角色=$(role_label)
场景=$(scene_label)
上行_Mbps=$UP_MBPS
下行_Mbps=$DOWN_MBPS
上游_RTT_ms=$UP_RTT
下游_RTT_ms=$DOWN_RTT
丢包率_pct=$LOSS_PCT
抖动_ms=$JITTER_MS
状态规则=$STATEFUL
落地路由=$LANDING_ROUTES
多出口_策略路由=$MULTIPATH
IPv6_RA依赖=$IPV6_RA
目标=$(target_label)
业务=$(business_label)

[自动检测和自动选择]
主网卡=$DEFAULT_IFACE
CPU核心=$CPU_COUNT
RX队列=$RX_QUEUES
TX队列=$TX_QUEUES
状态规则依据=$STATEFUL_REASON
落地路由依据=$LANDING_ROUTES_REASON
多出口_策略路由依据=$MULTIPATH_REASON
IPv6_RA依据=$IPV6_RA_REASON
本机终止TCP=$LOCAL_TCP_TERMINATION
本机终止TCP依据=$LOCAL_TCP_TERMINATION_REASON
TFO建连优化=$HANDSHAKE
TFO全局监听=$TFO_GLOBAL
TFO值=${TFO_VALUE:-已跳过}
TFO黑洞检测=系统默认（不写入）
busy_poll=${BUSY_POLL:-系统默认（不写入）}
RPS启用=$RPS_ENABLE
RPS_CPU掩码=$RPS_CPUS
RPS单队列流表=$RPS_FLOW_CNT
会话表并发强度_输入=$(choice_short_label "$CONCURRENCY_MODE")
会话表实际强度=$(choice_short_label "$CONCURRENCY_EFFECTIVE")
队列抖动保护=$QUEUE_JITTER_GUARD
低带宽初始窗口保护=交给内核自适应（不写 route initcwnd/initrwnd）
需要conntrack=$CT_NEEDED
模块开机加载=tcp_bbr, sch_fq

[生成的核心参数]
TCP并发=$TCP_CONNS
UDP会话=$UDP_SESSIONS
每秒新建连接=$CPS
内存预算_pct=$MEM_PCT
BDP_bytes=$BDP
BDP倍数=$BDP_MULT
TCP缓冲上限=$TCP_MAX
socket默认缓冲=系统默认（不写 rmem_default/wmem_default）
tcp_limit_output_bytes=$TCP_LIMIT
tcp_notsent_lowat=${TCP_NOTSENT_LOWAT:-系统默认（不写入）}
tcp_slow_start_after_idle=${TCP_SLOW_START_AFTER_IDLE:-系统默认（不写入）}
tcp_no_metrics_save=${TCP_NO_METRICS_SAVE:-系统默认（不写入）}
initcwnd=系统默认（仅清理旧 route initcwnd 残留）
initrwnd=系统默认（仅清理旧 route initrwnd 残留）
nofile=$NOFILE
TIME_WAIT上限=$TW_BUCKETS
fin_timeout=$FIN_TIMEOUT
netdev_max_backlog=$NETDEV_BACKLOG
netdev_max_backlog_cap=$NETDEV_BACKLOG_CAP
txqueuelen=系统/驱动默认（不写 ip link txqueuelen）
nf_conntrack_max=$NF_CONNTRACK_MAX
nf_conntrack_resource_cap=$CT_RESOURCE_CAP
nf_conntrack_hashsize=$NF_CONNTRACK_BUCKETS
不需要conntrack时的安全回落上限=系统默认（不写 nf_conntrack_max）

[系统自适应保留]
TCP协商能力=tcp_window_scaling/timestamps/sack/dsack 不写入
TCP路径学习=tcp_min_rtt_wlen/tcp_max_reordering 默认不写；tcp_no_metrics_save 只在前置/混合/落地路由多路径条件触发
发送队列细节=route initcwnd/txqueuelen 不写；tcp_notsent_lowat 只在小内存本机终止/落地条件触发
idle后慢启动=tcp_slow_start_after_idle 只在本机 TCP 终止且非纯 UDP 实时条件触发
应用心跳=tcp_keepalive_time/intvl/probes 不写入
纯落地机网络状态=不强行写 ip_forward=0/rp_filter

[生成文件]
sysctl=$SYSCTL_OUT
limits=$LIMITS_OUT
systemd=$SYSTEMD_OUT
route=$ROUTE_OUT
nic=$NIC_OUT
modprobe=$MODPROBE_OUT
modules_load=$MODULES_LOAD_OUT
report=$REPORT_OUT
rollback_apply后生成=$OUT_DIR/rollback.sh

[说明]
应用层_mux_multiplex=不会开启
复制这份报告给 Codex，可检查输入、自动选择和生成参数是否合理。
EOF

printf '\n已生成文件:\n'
printf '  %s\n' "$SYSCTL_OUT" "$LIMITS_OUT" "$SYSTEMD_OUT" "$ROUTE_OUT" "$NIC_OUT" "$REPORT_OUT"
printf '  %s\n' "$MODPROBE_OUT" "$MODULES_LOAD_OUT"
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
install_file "$MODULES_LOAD_OUT" /etc/modules-load.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$ROUTE_OUT" /usr/local/sbin/network-optimize-route.sh 0755 "$BACKUP_DIR"
install_file "$NIC_OUT" /usr/local/sbin/network-optimize-nic.sh 0755 "$BACKUP_DIR"

cat > "$OUT_DIR/network-optimize-route.service" <<'EOF'
[Unit]
Description=清理旧网络优化路由 initcwnd 残留
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
Description=应用网络优化网卡 RPS
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

try_load_module tcp_bbr || warn "tcp_bbr 模块加载失败；如果最终仍是 cubic，说明当前内核没有 BBR 模块或被宿主限制。"
try_load_module sch_fq || warn "sch_fq 模块加载失败；如果 default_qdisc=fq 应用失败，说明当前内核没有 fq qdisc 模块或被宿主限制。"
disable_legacy_initcwnd_enforcer
sysctl --system
apply_generated_sysctl_live "$SYSCTL_OUT"
sync_conntrack_hashsize_live
systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now network-optimize-route.service 2>/dev/null || true
systemctl enable --now network-optimize-nic.service 2>/dev/null || true

printf '\n本次输入、自动选择和生成参数报告（可整段复制给 Codex 检查）：\n'
printf '%s\n' '------------------------------------------------------------'
sed -n '1,220p' "$REPORT_OUT"
printf '%s\n' '------------------------------------------------------------'

print_final_sysctl_status

printf '\n已应用配置。回滚脚本: %s/rollback.sh\n' "$OUT_DIR"
printf '备份目录: %s\n' "$BACKUP_DIR"
if [[ "$CT_NEEDED" == "yes" ]]; then
  printf '如果 nf_conntrack hashsize 发生变化，建议重启系统让它完整生效。\n'
fi
printf '已从持久配置中移除可由系统自适应的硬指定项；旧运行态值如来自旧脚本，重启后会进一步回到系统/其他配置默认。\n'
