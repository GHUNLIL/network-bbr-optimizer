# 中文 BBR 网络优化脚本（Network BBR Optimizer）

中文交互式 Linux BBR 与网络转发优化脚本，默认先显示功能状态/当前参数，再进入功能选择菜单：推荐使用 `bpftune-first`，让 `oracle/bpftune` 做动态调优，本脚本只补转发/WG/Mimic/IPv6 RA 等拓扑缺口；如果应用时未检测到 bpftune，会先尝试用系统包管理器安装。专用转发、IX 专线、线路转发/国际互联仍可使用。

固定目标是“游戏低延迟 + UDP 实时优先 + 可控吞吐”：负载下尽量少排队，让游戏包、语音包、SSH 和小请求优先保持响应；同时保留 BBR、内核转发、conntrack、rp_filter/IPv6 RA 处理等转发机需要的能力。应用层 mux/smux/yamux/multiplex 默认不会开启。

默认业务按 `UDP 游戏/实时` 处理，不只偏 TCP；UDP socket 上限、conntrack UDP 容量、短连接回收和常见 TCP 基础能力都会一起计算，但 TCP 缓冲、`tcp_limit_output_bytes`、netdev backlog、RPS 自动开启条件会比重型转发模式更克制。

新版默认更尊重内核自适应：TCP 协商能力、ECN、RTT/重排路径学习、route `initcwnd/initrwnd`、`txqueuelen`、socket 默认缓冲、keepalive 等不再硬写。脚本只清理旧版可能残留在默认路由上的 `initcwnd/initrwnd`，之后交给内核、驱动、BBR 和应用按实际路径自适应。

应用新版配置时，脚本会停用旧版安装可能残留的 `initcwnd-enforcer.timer`。这个旧定时器会定期改默认路由窗口；新版会停用它并清理旧 route 窗口，让系统恢复自适应。

conntrack 会区分连接上限和 hash 表大小：`nf_conntrack_max` 仍按默认转发画像、转发场景、带宽、会话量和内存预算计算，`hashsize` 会按连接上限约 `1/8` 写入。这样可以避免某些内核在 `nf_conntrack` 模块加载时，把运行态连接上限自动膨胀到脚本目标值的数倍。

会话表并发强度默认保持 `balanced`：即使是转发节点，也先按低延迟游戏/实时流量处理，避免自动升到重型高并发画像后拉长队列。conntrack、nofile、listen backlog、SYN backlog、TIME_WAIT 和 netdev 队列仍会按带宽、内存、CPU、RX 队列和转发场景估算，但默认不为了测速吞吐主动放大到 `high/extreme`。

`线路转发` 和 `国际互联` 在新版里合并为同一个场景：都代表跨境、长 RTT、WG/Mimic 或公网中继链路，不再给“国际互联”单独套更保守的低缓冲配置。旧版或外部脚本传入的 `international` 名称仍会兼容处理，但按 `relay` 线路转发参数计算。

默认低延迟画像会收紧 `netdev_max_backlog` 与 TCP 发送队列：常见 1Gbps/80ms 输入下，TCP 缓冲上限会被压到 32MiB 内，`tcp_limit_output_bytes` 约 8MiB，`netdev_max_backlog` 通常约 32768，避免为了吞吐把小包压在长队列后面。

`stateful`、落地路由、多出口/策略路由、IPv6 RA、本机是否终止 TCP 这些容易误选的拓扑项也会自动推断：脚本会结合转发场景、当前默认路由、策略路由、NAT/TProxy 规则、隧道接口、IPv6 `proto ra` 默认路由和公开 TCP 监听端口判断，并在应用后的报告里列出判断依据。

如果检测到 IPv6 默认路由依赖 RA，脚本在开启 IPv6 forwarding 时会自动给默认网卡写 `accept_ra=2`，避免转发模式下内核停止接收 RA 后丢失 IPv6 默认路由。静态 IPv6 默认路由机器不会写这个接口项。

脚本会在应用配置前尝试加载 `tcp_bbr` 和 `sch_fq` 模块，并写入 `/etc/modules-load.d/99-network-optimize.conf` 让它们开机加载。这样普通 BBR1 内核即使初始只显示 `cubic reno`，只要系统提供 `tcp_bbr` 模块，也会正确切到 `net.ipv4.tcp_congestion_control = bbr`。

## 一键运行

推荐使用 `bootstrap.sh` 入口运行。入口会自动下载最新版 `bbr.sh` 并执行；默认显示“功能状态 / 当前参数 + 功能选择”菜单，非交互环境才直接进入 `bpftune-first`。下载脚本的 `auto` 模式会识别中国大陆网络，大陆服务器优先走 GitHub 代理，非大陆服务器优先直连，失败会自动换下一个地址。

仍然推荐 `bash <(curl -fsSL ...)`，不要用 `curl ... | bash`。进程替换可以让交互菜单继续从终端读取输入，管道可能占用标准输入，导致上下键菜单显示不完整或无法选择。

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
```

强制经典完整模式：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --classic
```

进入经典精简问答模式：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --quick
```

只生成配置、不应用到系统：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --dry-run
```

只读观测 softnet/UDP/TCP/conntrack 压力信号，不修改系统：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --audit 30
```

生成配置前先观测 30 秒，并把观测 delta 写入 `report.txt`：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --with-audit 30 --dry-run
```

以 `oracle/bpftune` 为主导，只补转发/WG/Mimic/IPv6 RA 等 bpftune 不覆盖的缺口：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --bpftune-first --dry-run
```

只应用 WireGuard/Mimic 隧道必需的 sysctl，不做 BBR、RPS、队列、conntrack 大优化：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --wgmimic-required
```

拉取并运行 `GHUNLIL/china-region-whitelist` 地区白名单脚本：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --china-whitelist
```

强制直连 GitHub：

```bash
BBR_GITHUB_PROXY=direct bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
```

手动指定其他 GitHub 代理：

```bash
BBR_GITHUB_PROXY=https://gh-proxy.com/ bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
```

## 保存后运行

```bash
curl -fL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
if [ "$(id -u)" -eq 0 ]; then bash ./bootstrap.sh; else sudo bash ./bootstrap.sh; fi
```

## 运行模式

```bash
bash bbr.sh                 # 功能状态/当前参数 + 功能选择菜单；非交互时默认 bpftune-first
bash bbr.sh --classic       # 强制经典完整优化，上下键可视化菜单
bash bbr.sh --quick         # 强制经典精简问答模式，只问转发场景和链路参数
bash bbr.sh --dry-run       # 只生成配置，不应用
bash bbr.sh --apply         # 生成配置，并询问是否应用
bash bbr.sh --audit 30      # 只读观测 30 秒，不生成、不应用配置
bash bbr.sh --with-audit 30 # 生成配置前先观测，并写入 report.txt
bash bbr.sh --bpftune-first # bpftune 主导，只补拓扑/转发/WG/Mimic 缺口
bash bbr.sh --wgmimic-required # 只应用 WG/Mimic 必需 sysctl
bash bbr.sh --china-whitelist  # 拉取并运行 china-region-whitelist
bash bbr.sh --out-dir DIR   # 指定输出目录
bash bbr.sh --clean-outputs # 清理旧版 bbr-output-* 和 /root/network-optimize-backup-* 目录
bash bbr.sh --help          # 查看帮助
```

## 菜单变化

打开脚本时，第一屏会先显示“功能状态 / 当前参数”：`bpftune` 是否安装、`bpftune.service` 是否运行、BBR/qdisc/TFO、IPv4/IPv6 forwarding、`rp_filter`、默认网卡 IPv6 RA、TCP buffer、netdev/NAPI、conntrack 当前用量、bpftune-first/经典配置文件是否已写入，以及最近一次输出目录。这样可以直接看到功能是否已经生效和关键参数是多少。

进入 `classic full` 后，主界面也会优先显示“系统已生效参数”，也就是从当前机器实时读取到的内核配置。修改转发场景或链路参数后，界面才会切换为“待生效配置草案”，避免把脚本默认值误认为系统当前值。

交互界面不再询问“机器角色”“优化目标”“业务类型”“BBR 版本假设”“stateful”“多出口/策略路由”“IPv6 RA”“落地路由”这些容易误选的分支；脚本默认按转发节点处理，固定使用响应优先、`UDP 游戏/实时` 和 BBR 自动/未知公式。RPS、TFO、busy_poll、会话表并发强度、TCP/UDP/CPS 容量都会在“生成配置并确认是否应用”时按转发场景、带宽、RTT、内存、CPU、网卡队列和当前路由/防火墙状态自动判断。

界面会保留 `BBR`、`TFO`、`RPS`、`nftables`、`conntrack`、`sysctl`、`busy_poll` 等英文技术术语，但自动项不再单独占主菜单。主菜单末尾提供 `china-region-whitelist` 拉取入口，用于跳转到地区白名单防火墙脚本。

如果没有修改任何参数就选择“生成配置”，脚本会先确认是否仍然使用默认草案生成。

`--wgmimic-required` 是给 WireGuard + Mimic 隧道的一键最小配置：只开启 IPv4/IPv6 转发、关闭 rp_filter、关闭 redirects/source route 等会影响隧道路由的项目，不会改 BBR、队列、RPS 或 conntrack 容量。完整加速仍走普通生成/应用流程。

应用完成后，脚本会打印一段“本次输入、自动选择和生成参数报告”，里面包含你输入的转发场景/带宽/RTT/丢包抖动、脚本自动判断的 stateful/落地路由/多出口/IPv6 RA/RPS/TFO/busy_poll/会话表强度和判断依据，以及最终生成的核心参数。报告也会列出哪些项目已交回系统自适应，可以整段复制给 Codex 检查是否合理。

`--audit` / `--with-audit` 会按 bpftune 的观测驱动思路读取内核计数器：`/proc/net/softnet_stat`、`/proc/net/snmp`、`/proc/net/netstat`、`/proc/net/sockstat`、conntrack 当前使用量和邻居表数量。它只做前后采样 delta，不写 sysctl、不改 systemd、不加载模块；适合判断是否真的存在 backlog 丢包、NAPI budget 不足、UDP 缓冲错误、TCP listen backlog 溢出或 conntrack 接近满表。

## bpftune-first 方案

默认运行时，脚本会进入 `bpftune-first`；如果系统未安装 [oracle/bpftune](https://github.com/oracle/bpftune)，应用时会先尝试自动安装。你也可以用 `--classic` 强制回到原完整优化。这个模式会生成 `bpftune-first-report.txt` 和 `98-bpftune-first-bridge.conf`：

- `bpftune` 负责动态性能调优：TCP/UDP buffer、netdev backlog/budget、邻居表、IP fragment、TCP congestion 连接级选择、sysctl 手动覆盖退让。
- 本脚本只补 `bpftune` 不覆盖或不应该替你猜的拓扑项：IPv4/IPv6 forwarding、IPv6 RA 保留、`rp_filter`、redirect/source-route、WG/Mimic 隧道路由必需项。
- 本模式故意不写 `tcp_rmem/tcp_wmem`、`rmem_max/wmem_max`、`netdev_max_backlog`、`netdev_budget`、`nf_conntrack_max`、`default_qdisc`、`tcp_congestion_control`，避免和 bpftune 的 tuner 抢控制权。
- 如果旧版经典模式留下了 `/etc/sysctl.d/99-network-optimize.conf`，`bpftune-first` 应用时会先备份再改名为 `.disabled-by-bpftune-first`，避免 `sysctl --system` 继续加载旧 TCP buffer、BBR/qdisc、backlog、conntrack 等固定参数。

推荐流程：

```bash
# 1. 先看机器是否有 bpftune 和 BPF 支持
bash bbr.sh --dry-run

# 2. 如果报告合理，再应用补缺项；没有 bpftune 时会先尝试安装，随后启动 bpftune.service
sudo bash bbr.sh --apply

# 3. 之后用只读观测确认是否还有 UDP/backlog/conntrack 压力
bash bbr.sh --audit 30
```

如果机器没有安装 bpftune，`--apply` 会按 `dnf/yum/apt-get/zypper/pacman` 顺序尝试安装系统包。发行版没有 bpftune 包或安装失败时，报告会保留 `bpftune-install.log` 供排查；需要禁用自动安装时可用 `--no-install-bpftune` 或设置 `BBR_INSTALL_BPFTUNE=no`。需要强制回到原完整优化时，可以使用 `--classic` 或设置 `BBR_BPFTUNE_FIRST=no`。

## 输出目录

新版默认不会继续在当前目录生成一堆 `bbr-output-*` 文件夹。

默认输出位置：

```text
$HOME/.local/state/network-bbr-optimizer/runs/<时间戳>
```

最近一次输出会链接到：

```text
$HOME/.local/state/network-bbr-optimizer/latest
```

默认备份位置：

```text
$HOME/.local/state/network-bbr-optimizer/backups/<时间戳>
```

最近一次备份会链接到：

```text
$HOME/.local/state/network-bbr-optimizer/latest-backup
```

如果你想指定输出目录，可以使用：

```bash
bash bbr.sh --out-dir /root/bbr-output
```

## 默认画像说明

- 脚本默认按转发节点优化，包括前置入口、IX 专线、线路转发/国际互联和普通 nftables 转发。
- 纯转发场景不会默认开启 TCP Fast Open，因为 nftables 内核转发不终止 TCP 连接，单边开启 TFO 对被转发连接没有实际帮助。
- 建站或应用层服务机器也可以使用，但不是主要优化目标；这类机器的公开 TCP 监听、NAT/TProxy、隧道接口和现有 forwarding 状态会作为自动判断依据。
- 脚本会在应用实时配置前生成回滚文件。
- BBR1/未知内核都会尝试启用 `bbr` 拥塞控制；脚本不再全局强写 ECN，保留内核默认策略和对端协商。

## 术语备注

- BBR：Linux TCP 拥塞控制算法。
- sysctl：Linux 内核参数配置接口。
- nftables：Linux 防火墙和内核转发规则框架。
- RPS：Receive Packet Steering，用于把网卡收包处理分散到多个 CPU。
- conntrack：连接跟踪，NAT、状态防火墙和部分转发规则会用到。
- initcwnd / initrwnd：路由级 TCP 初始拥塞窗口和初始接收窗口；新版默认不指定，只清理旧残留。
- nofile：进程可打开文件描述符上限。
- TCP Fast Open / TFO：减少 TCP 建连握手延迟的机制，只对本机发起或本机终止的 TCP 连接有意义。
