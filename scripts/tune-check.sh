#!/usr/bin/env bash
#
# tune-check.sh — report current kernel tunables vs the recommended values
# from ../sysctl/*.conf. STRICTLY READ-ONLY: this script never writes a knob.
#
# Usage: ./tune-check.sh
# Exit code: 0 if everything matches, 1 if any value differs.

set -euo pipefail

# Recommended values: keep in sync with sysctl/99-network-tuning.conf
# and sysctl/99-vm-tuning.conf.
read -r -d '' RECOMMENDED <<'EOF' || true
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=8192
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=5
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
vm.swappiness=1
vm.dirty_background_bytes=268435456
vm.dirty_bytes=1073741824
vm.dirty_expire_centisecs=1000
vm.dirty_writeback_centisecs=500
vm.min_free_kbytes=1048576
vm.overcommit_memory=0
vm.panic_on_oom=0
kernel.numa_balancing=0
kernel.sched_autogroup_enabled=0
EOF

if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

mismatches=0
missing=0

printf "%-45s %-20s %-20s %s\n" "KEY" "CURRENT" "RECOMMENDED" "STATUS"
printf '%.0s-' {1..100}; printf '\n'

while IFS='=' read -r key expected; do
    [[ -z "$key" ]] && continue
    # sysctl -n prints tab-separated values for multi-value keys.
    if current=$(sysctl -n "$key" 2>/dev/null); then
        current=${current//$'\t'/ }
        if [[ "$current" == "$expected" ]]; then
            printf "%-45s %-20s %-20s %sok%s\n" \
                "$key" "$current" "$expected" "$GREEN" "$RESET"
        else
            printf "%-45s %-20s %-20s %sDIFFERS%s\n" \
                "$key" "$current" "$expected" "$RED" "$RESET"
            mismatches=$((mismatches + 1))
        fi
    else
        printf "%-45s %-20s %-20s %sMISSING%s\n" \
            "$key" "-" "$expected" "$YELLOW" "$RESET"
        missing=$((missing + 1))
    fi
done <<< "$RECOMMENDED"

# Non-sysctl knobs -----------------------------------------------------------

thp_file=/sys/kernel/mm/transparent_hugepage/enabled
if [[ -r "$thp_file" ]]; then
    thp_current=$(grep -o '\[.*\]' "$thp_file" | tr -d '[]')
    if [[ "$thp_current" == "madvise" || "$thp_current" == "never" ]]; then
        printf "%-45s %-20s %-20s %sok%s\n" \
            "transparent_hugepage" "$thp_current" "madvise|never" "$GREEN" "$RESET"
    else
        printf "%-45s %-20s %-20s %sDIFFERS%s\n" \
            "transparent_hugepage" "$thp_current" "madvise|never" "$RED" "$RESET"
        mismatches=$((mismatches + 1))
    fi
fi

echo
echo "Summary: ${mismatches} mismatched, ${missing} not present on this kernel."
echo "This script is read-only. Apply changes by installing the sysctl/*.conf"
echo "files and running 'sysctl --system' — after load-testing each change."

[[ "$mismatches" -eq 0 ]]
