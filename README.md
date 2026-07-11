# 中文 BBR 网络优化脚本（Network BBR Optimizer）

面向 Linux 转发节点、上网代理链路和低延迟实时流量的交互式 BBR / sysctl 优化脚本。脚本默认优先保证响应速度和 UDP 实时体验，同时保留转发、conntrack、RPS、IPv6 RA、TFO 等常见网络节点需要的自动判断能力。

## 一键运行

推荐使用 `bootstrap.sh` 入口。它会自动下载最新版 `bbr.sh` 并执行；默认会识别中国大陆网络，大陆服务器优先走 GitHub 代理，非大陆服务器优先直连，失败时自动切换备用地址。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
```

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh)
```

> 推荐使用 `bash <(curl -fsSL ...)`，不要用 `curl ... | bash`。进程替换可以让交互菜单继续从终端读取输入，避免上下键菜单显示不完整或无法选择。

## 适用场景

| 场景 | 说明 | 默认侧重 |
| --- | --- | --- |
| `front` 前置入口 | 用户进入的第一跳转发，例如家宽入口或入口机 | 实时响应、小包优先 |
| `relay` 中继转发 | 跨网、跨境、长 RTT、WG/Mimic 或公网中继 | 中继吞吐、长 RTT 适配 |
| `ix` 专线/IX 转发 | 专线 / IX 汇聚跳，低丢包、低抖动转发 | 转发能力、低排队 |
| `landing` 落地出口 | 本机代理/隧道出口，终止 TCP/UDP 会话 | TCP+UDP 双优化 |
| `hybrid` 混合网络节点 | 本机终止和转发链路并存 | 本机终止 + 转发混合 |

旧版或外部脚本传入的 `international` 会兼容映射到 `relay`，`aws` 会兼容映射到 `hybrid`。这两个只是旧名称兼容，不再作为正式分类。

## 默认策略

- 默认场景为 `relay` 中继转发，不再提供普通 nftables 转发兜底选项。
- 前置、中继和专线/IX 转发默认按 `UDP 游戏/实时` 处理；落地出口和混合网络节点默认按 `TCP+UDP 双优化` 处理。
- 固定目标是低延迟、少排队、可控吞吐：优先照顾游戏包、语音包、SSH 和小请求，再保留持续吞吐能力。
- 不默认开启应用层 mux / smux / yamux / multiplex。
- 纯内核转发场景不会默认开启 TCP Fast Open，因为 nftables 转发不终止 TCP 连接，单边开启 TFO 对被转发连接没有实际帮助。
- 脚本会自动判断 stateful、落地路由、多出口/策略路由、IPv6 RA、本机是否终止 TCP、RPS、TFO、busy_poll 和会话表强度；分类只表达网络角色，不按云厂商或业务面板判断。
- FQ 仅在 `tc -s` 已有实测压力证据时放宽，并将生成前核心参数写入网卡脚本用于回滚，同时保存完整 qdisc 快照。
- 目标带宽达到 300 Mbps 且只有 1 vCPU 时，UDP 中继报告会给出 CPU/PPS 容量告警，不用扩大缓冲掩盖算力上限。

## 运行参数

一键运行命令后面可以追加参数；保存后的 `bbr.sh` 也支持同样参数。

| 参数 | 用途 |
| --- | --- |
| `--quick` | 精简问答模式，只问转发场景和链路参数 |
| `--dry-run` | 只生成配置文件，不应用到系统 |
| `--apply` | 生成配置后默认询问是否应用 |
| `--wgmimic-required` | 只应用 WireGuard / Mimic 隧道必需 sysctl，不做完整网络优化 |
| `--relay-audit` | 只读审计 UDP socket、FQ、Mimic XDP、CPU 和队列瓶颈 |
| `--mimic-native` | 对 virtio_net 上已有 Mimic 做 native XDP 安全尝试，验证失败自动回滚 |
| `--china-whitelist` | 拉取并运行 `GHUNLIL/china-region-whitelist` 地区白名单脚本 |
| `--out-dir DIR` | 指定输出目录 |
| `--clean-outputs` | 清理旧版 `bbr-output-*` 和 `/root/network-optimize-backup-*` 目录 |
| `--help` | 查看脚本帮助 |

如果需要调整 GitHub 访问方式，可以在运行前设置 `BBR_GITHUB_PROXY`：`direct` 表示强制直连，也可以填入自定义代理前缀，例如 `https://gh-proxy.com/`。

## 实测型 ForwardX / Mimic 优化

先运行只读审计，不会修改服务、qdisc 或 sysctl：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --relay-audit
```

审计会显示默认网卡、驱动、CPU/RX/TX 队列、Mimic 配置和实际 XDP 模式、UDP/IP 丢弃计数，以及 `tc -s` 中的 `dropped/flows_plimit` 证据。累计计数只用于定位候选层，最终仍应使用相同方向、速率和包长做负载窗口 A/B。

如果审计发现 virtio_net 上的 Mimic 被强制为 `xdp_mode = skb`，可先生成变更计划：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --mimic-native --dry-run
```

确认后应用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bootstrap.sh) --mimic-native --apply
```

该操作只默认接受已验证的 `virtio_net` 候选，备份 `/etc/mimic/<接口>.conf`，短暂重启对应的 `mimic@<接口>.service`，并同时验证服务为 active、运行态确实显示 native XDP。任何一步失败都会立即恢复原配置并重启服务；输出目录还会生成独立回滚脚本。

完整优化模式也会读取现有 `fq` qdisc。只有生成时已经看到 `dropped/flows_plimit`，或队列已经使用已验证的放宽画像，才会把对应 root/多队列子 qdisc 持久化为 `limit 100000 / flow_limit 1000 / buckets 4096`。其它队列保持原值，回滚时恢复生成前记录的三个核心参数，完整原始状态保存在 `qdisc-before.txt`。这样可以修复高带宽单 UDP 流触发的 `flows_plimit`，不会把所有机器一律改成大队列。

> 1 vCPU 的 Mimic/FXP 在高 PPS 下常先撞到 CPU、system 和 softirq 上限。native XDP 可以降低一部分开销，但无法创造额外 CPU 容量；如果负载期间 CPU 已持续 100%，继续放大 socket、backlog 或 conntrack 通常不能把 540 Mbps 变成低丢包。应先降低限速/包速，或升级到至少 2 vCPU 后重新测量。

## 交互菜单

打开脚本时，主界面会先显示可上下键选择的高亮菜单，再显示当前机器已经生效的关键内核参数预览。完整实时参数可以进入 `live sysctl` 查看。

所有选项面板都会优先使用上下键高亮选择，也支持 `j/k` 移动、Enter 确认；只有在没有控制终端时才退回编号输入。

主菜单只保留常用入口：

| 菜单 | 作用 |
| --- | --- |
| `scene` | 选择转发场景 |
| `bandwidth/RTT/loss` | 输入带宽、延迟、丢包和抖动 |
| `generate/apply` | 生成配置，并确认是否应用 |
| `live sysctl` | 查看系统已生效参数 |
| `china-region-whitelist` | 拉取中国地区白名单脚本 |
| `exit` | 退出 |

脚本不再单独询问机器角色、优化目标、业务类型、BBR 版本假设、stateful、多出口、IPv6 RA、落地路由等容易误选的分支。这些项目会在生成配置时按转发场景、链路参数、内存、CPU、网卡队列和当前路由/防火墙状态自动推断。

应用完成后，脚本会输出“本次输入、自动选择和生成参数报告”。报告包含场景、带宽、RTT、丢包抖动、自动判断依据、生成的核心参数，以及哪些项目已交回系统自适应。

## 输出目录

新版默认不会在当前目录生成一堆 `bbr-output-*` 文件夹。

| 类型 | 默认位置 |
| --- | --- |
| 本次输出 | `$HOME/.local/state/network-bbr-optimizer/runs/<时间戳>` |
| 最近输出链接 | `$HOME/.local/state/network-bbr-optimizer/latest` |
| 本次备份 | `$HOME/.local/state/network-bbr-optimizer/backups/<时间戳>` |
| 最近备份链接 | `$HOME/.local/state/network-bbr-optimizer/latest-backup` |

脚本应用实时配置前会生成回滚文件。

`--mimic-native` 会额外生成 `mimic-native-plan.txt` 和 `rollback-mimic-native.sh`。

## 关键行为

- BBR1 / 未知内核都会尝试启用 `bbr` 拥塞控制。
- 脚本会尝试加载 `tcp_bbr` 和 `sch_fq` 模块，并写入 `/etc/modules-load.d/99-network-optimize.conf` 让它们开机加载。
- 脚本不再全局强写 ECN，保留内核默认策略和对端协商。
- TCP 协商能力、RTT/重排路径学习、route `initcwnd/initrwnd`、`txqueuelen`、socket 默认缓冲和 keepalive 等默认交给内核、驱动、BBR 和应用自适应；UDP socket 出现丢包时先区分应用读取速度、CPU 和路径，不盲目提高全局默认缓冲。
- 应用新版配置时，会停用旧版可能残留的 `initcwnd-enforcer.timer`，并清理旧 route 窗口。
- 应用新版配置时，会备份并移除 `/etc/sysctl.d` 中其它写入本脚本负责网络优化参数的 sysctl 文件，并备份后注释 `/etc/sysctl.conf` 中脚本负责的单行，让 `/etc/sysctl.d/99-network-optimize.conf` 成为唯一主配置。匹配按 sysctl key 自动识别，不按旧文件名写死；`98-wgmimic-required.conf`、README、以及 disabled/bak/old/orig/save 文件会保留。接管结果会直接显示在终端总结里，不需要查看单独报告文件，回滚脚本会恢复被接管移除/注释前的文件。
- conntrack 会区分连接上限和 hash 表大小：`nf_conntrack_max` 按转发画像、场景、带宽、会话量和内存预算计算，`hashsize` 按连接上限约 `1/8` 写入。
- 如果检测到 IPv6 默认路由依赖 RA，脚本在开启 IPv6 forwarding 时会给默认网卡写 `accept_ra=2`，避免转发模式下丢失 IPv6 默认路由。

## 术语备注

| 术语 | 含义 |
| --- | --- |
| BBR / BBR3 | Linux TCP 拥塞控制算法 |
| sysctl | Linux 内核参数配置接口 |
| nftables | Linux 防火墙和内核转发规则框架 |
| RPS | Receive Packet Steering，用于把网卡收包处理分散到多个 CPU |
| conntrack | 连接跟踪，NAT、状态防火墙和部分转发规则会用到 |
| initcwnd / initrwnd | 路由级 TCP 初始拥塞窗口和初始接收窗口 |
| nofile | 进程可打开文件描述符上限 |
| TCP Fast Open / TFO | 减少 TCP 建连握手延迟的机制，只对本机发起或本机终止的 TCP 连接有意义 |
