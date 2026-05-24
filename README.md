# Network BBR Optimizer

Interactive Linux BBR and network forwarding optimizer for dedicated forwarding and landing nodes.

The script uses a visual arrow-key menu by default. It generates aggressive full-speed network tuning with controlled queue depth and jitter, covers BBR/sysctl/RPS/conntrack/initcwnd/nofile/TCP Fast Open output, and keeps application-layer mux/multiplex disabled by default.

## One-Line Run

Recommended interactive one-line command:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh)'
```

Use the command above for the interactive UI. Avoid `curl ... | bash` for interactive runs because piping can steal stdin from the menu on some systems.

Generate files only, without applying:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh) --dry-run
```

Linear question mode:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh) --quick'
```

## Save And Run

```bash
curl -fsSL https://raw.githubusercontent.com/GHUNLIL/network-bbr-optimizer/main/bbr.sh -o bbr.sh
chmod +x bbr.sh
sudo ./bbr.sh
```

## Modes

```bash
bash bbr.sh             # visual arrow-key menu
bash bbr.sh --quick     # linear wizard
bash bbr.sh --dry-run   # generate config only
bash bbr.sh --apply     # generate and ask to apply
bash bbr.sh --help
```

## Notes

- Forwarding nodes include front forwarding, IX dedicated forwarding, relay forwarding, international forwarding, and plain nftables forwarding.
- Landing nodes are application egress machines such as 3x-ui/Xray by default.
- Pure forwarding nodes do not enable TCP Fast Open unless the machine also terminates local TCP.
- Application-layer mux/smux/yamux/multiplex is not enabled by this script.
- The script generates rollback files before applying live changes.
