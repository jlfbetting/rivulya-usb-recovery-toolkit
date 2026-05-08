#!/usr/bin/env bash
set -euo pipefail

net_iface=${1:-}
blink_seconds=${2:-10}

if [[ -n "$net_iface" ]] && command -v ethtool >/dev/null 2>&1; then
    ethtool -p "$net_iface" "$blink_seconds" >/dev/null 2>&1 &
fi

modprobe pcspkr >/dev/null 2>&1 || true

if command -v beep >/dev/null 2>&1; then
    beep -f 880 -l 120 -r 2 -d 80 >/dev/null 2>&1 || true
    exit 0
fi

if [[ -w /dev/console ]]; then
    printf '\a' > /dev/console || true
    printf '\a' > /dev/console || true
fi
