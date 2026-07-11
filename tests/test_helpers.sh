#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/tc" <<'EOF'
#!/usr/bin/env bash
cat "$TC_FIXTURE"
EOF
chmod +x "$TEST_DIR/bin/tc"

export PATH="$TEST_DIR/bin:$PATH"
export BBR_LIBRARY_ONLY=yes
# shellcheck source=/dev/null
source "$ROOT_DIR/bbr.sh"

cat >"$TEST_DIR/qdisc-pressure.txt" <<'EOF'
qdisc mq 1: root
 Sent 100 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)
qdisc fq 0: parent 1:2 limit 10000p flow_limit 100p buckets 1024
 Sent 100 bytes 10 pkt (dropped 7, overlimits 0 requeues 0)
  flows 2 (inactive 2 throttled 0) flows_plimit 7
qdisc fq 0: parent 1:1 limit 100000p flow_limit 1000p buckets 4096
 Sent 100 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)
EOF
export TC_FIXTURE="$TEST_DIR/qdisc-pressure.txt"
actual="$(detect_fq_tuning_records eth0)"
expected=$'parent:1:2|10000|100|1024|measured-pressure\nparent:1:1|100000|1000|4096|existing-profile'
[[ "$actual" == "$expected" ]] || {
  printf 'unexpected fq records:\n%s\n' "$actual" >&2
  exit 1
}

cat >"$TEST_DIR/qdisc-clean.txt" <<'EOF'
qdisc fq 8001: root limit 10000p flow_limit 100p buckets 1024
 Sent 100 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)
  flows 2 (inactive 2 throttled 0)
EOF
export TC_FIXTURE="$TEST_DIR/qdisc-clean.txt"
[[ -z "$(detect_fq_tuning_records eth0)" ]]

cat >"$TEST_DIR/mimic.conf" <<'EOF'
log.verbosity = info
xdp_mode = skb
EOF
[[ "$(mimic_configured_xdp_mode "$TEST_DIR/mimic.conf")" == "skb" ]]

printf 'helper tests passed\n'
