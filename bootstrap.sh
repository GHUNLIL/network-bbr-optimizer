#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="GHUNLIL"
REPO_NAME="network-bbr-optimizer"
REPO_BRANCH="${BBR_REPO_BRANCH:-${CN_REPO_BRANCH:-main}}"
DEFAULT_PROXY_URL="${BBR_GITHUB_PROXY_URL:-https://gh-proxy.com/}"
GITHUB_PROXY="${BBR_GITHUB_PROXY:-${CN_GITHUB_PROXY:-auto}}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/bbr.sh"
BOOTSTRAP_WORK_DIR=""

usage() {
  cat <<'EOF'
network-bbr-optimizer bootstrap

自动下载最新版 bbr.sh 并执行。bbr.sh 默认显示功能状态/当前参数和功能选择菜单；非交互时
进入 bpftune-first，应用时未安装 bpftune 会先尝试安装。下载脚本的 auto 模式会识别中国大陆网络，
大陆服务器优先走 GitHub 代理，非大陆服务器优先直连；失败会自动换下一个地址。

用法：
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) [bbr.sh 参数]

常用：
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --classic
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --quick
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --audit 30
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --with-audit 30 --dry-run
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --bpftune-first --dry-run
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --wgmimic-required
  bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --china-whitelist

环境变量：
  BBR_GITHUB_PROXY=auto                 默认；自动识别大陆网络并选择代理/直连
  BBR_GITHUB_PROXY=direct               强制直连 GitHub
  BBR_GITHUB_PROXY=https://gh-proxy.com/ 强制使用指定 GitHub 代理前缀
  BBR_GITHUB_PROXIES="https://gh-proxy.com/ direct"
  BBR_REPO_BRANCH=main

兼容变量：
  CN_GITHUB_PROXY / CN_GITHUB_PROXIES / CN_REPO_BRANCH
EOF
}

proxy_url() {
  local raw_url="$1"
  local proxy="$2"
  case "${proxy}" in
    ""|direct|none)
      printf '%s\n' "${raw_url}"
      ;;
    */)
      printf '%s%s\n' "${proxy}" "${raw_url}"
      ;;
    *)
      printf '%s/%s\n' "${proxy}" "${raw_url}"
      ;;
  esac
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少命令：${command_name}" >&2
    exit 1
  fi
}

country_probe() {
  local body
  body="$(curl -fsSL --connect-timeout 2 --max-time 4 https://ipapi.co/country 2>/dev/null || true)"
  if [[ "${body}" =~ ^CN ]]; then
    return 0
  fi

  body="$(curl -fsSL --connect-timeout 2 --max-time 4 https://ifconfig.co/country-iso 2>/dev/null || true)"
  if [[ "${body}" =~ ^CN ]]; then
    return 0
  fi

  body="$(curl -fsSL --connect-timeout 2 --max-time 4 https://myip.ipip.net 2>/dev/null || true)"
  if [[ "${body}" == *"中国"* || "${body}" == *"China"* || "${body}" == *"CN"* ]]; then
    return 0
  fi

  return 1
}

proxy_candidates() {
  local candidates mode
  candidates="${BBR_GITHUB_PROXIES:-${CN_GITHUB_PROXIES:-}}"
  if [[ -n "${candidates}" ]]; then
    printf '%s\n' "${candidates//,/ }"
    return 0
  fi

  mode="${GITHUB_PROXY}"
  case "${mode}" in
    ""|auto)
      if country_probe; then
        echo "检测到中国大陆网络，优先使用 GitHub 代理。" >&2
        printf '%s direct\n' "${DEFAULT_PROXY_URL}"
      else
        echo "未检测到中国大陆网络，优先直连 GitHub；失败会自动尝试代理。" >&2
        printf 'direct %s\n' "${DEFAULT_PROXY_URL}"
      fi
      ;;
    direct|none)
      printf 'direct\n'
      ;;
    *)
      printf '%s direct\n' "${mode}"
      ;;
  esac
}

download_script() {
  local target="$1"
  local proxy url
  for proxy in $(proxy_candidates); do
    url="$(proxy_url "${SCRIPT_URL}" "${proxy}")"
    echo "正在下载：${url}" >&2
    if curl -fL --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 1 -o "${target}" "${url}"; then
      return 0
    fi
    echo "下载失败，尝试下一个地址。" >&2
  done

  echo "无法下载 bbr.sh，请检查网络，或设置 BBR_GITHUB_PROXY=https://gh-proxy.com/" >&2
  return 1
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  require_command curl
  require_command mktemp

  local script_path
  BOOTSTRAP_WORK_DIR="$(mktemp -d)"
  script_path="${BOOTSTRAP_WORK_DIR}/bbr.sh"
  trap '[[ -n "${BOOTSTRAP_WORK_DIR:-}" ]] && rm -rf "${BOOTSTRAP_WORK_DIR}"' EXIT

  download_script "${script_path}"
  chmod +x "${script_path}"
  exec bash "${script_path}" "$@"
}

main "$@"
