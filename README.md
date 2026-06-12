# 中文 BBR 网络优化脚本（Network BBR Optimizer）

中文交互式 Linux BBR 与网络转发优化脚本，面向专用转发节点、IX 专线转发、线路中继、国际互联转发和落地节点。

固定目标是“极致满速 + TCP+UDP 双优化 + 可控低抖动”：让测速、新连接和长 RTT 链路尽快跑满，同时限制队列深度，避免无意义堆积。脚本会生成并可应用 BBR、sysctl、RPS、conntrack、initcwnd、nofile、TCP Fast Open 等配置；应用层 mux/smux/yamux/multiplex 默认不会开启。

默认业务按 `TCP+UDP 双优化` 处理，不只偏 TCP；UDP 会话、UDP socket 缓冲、netdev 队列、conntrack UDP 容量、socket 默认缓冲、短连接回收和常见 TCP 基础能力都会一起计算。

低带宽跨境转发会自动收敛路由初始窗口：当前置入口、IX 专线、线路中继或国际互联场景的瓶颈带宽不高于 `10Mbps` 时，脚本会把 `initcwnd/initrwnd` 从高强度测速窗口降到更稳的低突发窗口。例如 `5Mbps` IX 专线会生成 `initcwnd 64 initrwnd 64`，避免一开连接就把小带宽链路塞出排队和抖动。

应用新版配置时，脚本会停用旧版安装可能残留的 `initcwnd-enforcer.timer`。这个旧定时器会定期改默认路由窗口，可能和新版 `network-optimize-route.service` 抢 `initcwnd/initrwnd`，也可能在新配置下反复失败刷日志。

conntrack 会区分连接上限和 hash 表大小：`nf_conntrack_max` 仍按机器角色、带宽、会话量和内存预算计算，`hashsize` 会按连接上限约 `1/8` 写入。这样可以避免某些内核在 `nf_conntrack` 模块加载时，把运行态连接上限自动膨胀到脚本目标值的数倍。

脚本会在应用配置前尝试加载 `tcp_bbr` 和 `sch_fq` 模块，并写入 `/etc/modules-load.d/99-network-optimize.conf` 让它们开机加载。这样普通 BBR1 内核即使初始只显示 `cubic reno`，只要系统提供 `tcp_bbr` 模块，也会正确切到 `net.ipv4.tcp_congestion_control = bbr`。

## 一键运行

推荐使用下面这个命令进入上下键可视化菜单：

```bash
TMP_BBR=/tmp/network-bbr-optimizer.sh; curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh?$(date +%s)" -o "$TMP_BBR" && sudo bash "$TMP_BBR"
```

这个命令会先把脚本下载到临时文件，再用 `bash` 执行，适合交互式菜单。不要用 `curl ... | bash` 运行交互菜单，因为管道可能占用标准输入，导致上下键菜单显示不完整或无法选择。

只生成配置、不应用到系统：

```bash
TMP_BBR=/tmp/network-bbr-optimizer.sh; curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh?$(date +%s)" -o "$TMP_BBR" && bash "$TMP_BBR" --dry-run
```

使用逐项问答模式：

```bash
TMP_BBR=/tmp/network-bbr-optimizer.sh; curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh?$(date +%s)" -o "$TMP_BBR" && sudo bash "$TMP_BBR" --quick
```

## 保存后运行

```bash
curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh -o bbr.sh
chmod +x bbr.sh
sudo ./bbr.sh
```

## 运行模式

```bash
bash bbr.sh                 # 上下键可视化菜单
bash bbr.sh --quick         # 逐项问答模式
bash bbr.sh --dry-run       # 只生成配置，不应用
bash bbr.sh --apply         # 生成配置，并询问是否应用
bash bbr.sh --out-dir DIR   # 指定输出目录
bash bbr.sh --clean-outputs # 清理旧版 bbr-output-* 和 /root/network-optimize-backup-* 目录
bash bbr.sh --help          # 查看帮助
```

## 菜单变化

打开脚本时，主界面优先显示“系统已生效参数”，也就是从当前机器实时读取到的内核配置。修改 1-5 项之后，界面才会切换为“待生效配置草案”，避免把脚本默认值误认为系统当前值。

交互界面不再询问“优化目标”“业务类型”“BBR 版本假设”这几个容易误选的分支；脚本固定使用极致满速、`TCP+UDP 双优化` 和 BBR 自动/未知公式。需要调整强度时，使用带宽、RTT、丢包、抖动和高级覆盖项。

界面会保留 `BBR`、`TFO`、`RPS`、`nftables`、`conntrack`、`sysctl`、`busy_poll` 等英文技术术语，并在菜单选项和问题标题里附中文备注。例如 `NIC/RPS/busy_poll - 网卡队列、收包分流、低延迟轮询`。

如果没有修改任何参数就选择“生成配置”，脚本会先确认是否仍然使用默认草案生成。

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

## 角色说明

- 转发节点：包括前置入口、IX 专线、线路中继、国际互联和普通 nftables 转发。
- 落地节点：默认指 3x-ui、Xray、GOST 等应用层出口机器。
- 纯转发节点不会默认开启 TCP Fast Open，因为 nftables 内核转发不终止 TCP 连接，单边开启 TFO 对被转发连接没有实际帮助。
- 落地节点默认不启用内核转发；只有机器同时承担 NAT、路由或 nftables 转发时才需要开启。
- 脚本会在应用实时配置前生成回滚文件。
- BBR1/未知内核都会尝试启用 `bbr` 拥塞控制；`BBR3` 选项只影响计算倍数和 ECN 策略，不代表只有 BBR3 才能启用 BBR。

## 术语备注

- BBR：Linux TCP 拥塞控制算法。
- sysctl：Linux 内核参数配置接口。
- nftables：Linux 防火墙和内核转发规则框架。
- RPS：Receive Packet Steering，用于把网卡收包处理分散到多个 CPU。
- conntrack：连接跟踪，NAT、状态防火墙和部分转发规则会用到。
- initcwnd / initrwnd：路由级 TCP 初始拥塞窗口和初始接收窗口。
- nofile：进程可打开文件描述符上限。
- TCP Fast Open / TFO：减少 TCP 建连握手延迟的机制，只对本机发起或本机终止的 TCP 连接有意义。
