#!/usr/bin/env bash
set -euo pipefail

result_dir=${RIVULYA_TOOLKEY_RESULT_DIR:?missing RIVULYA_TOOLKEY_RESULT_DIR}
default_iface=${RIVULYA_TOOLKEY_DEFAULT_INTERFACE:-}
server_id=${RIVULYA_TOOLKEY_SERVER_ID:-}

capture_cmd() {
    local file_name=$1
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "$result_dir/$file_name" 2>&1 || true
}

capture_sh() {
    local file_name=$1
    local script=$2
    {
        printf '$ sh -c %q\n' "$script"
        sh -c "$script"
    } > "$result_dir/$file_name" 2>&1 || true
}

find_physical_iface() {
    local iface
    for path in /sys/class/net/*; do
        iface=$(basename -- "$path")
        case "$iface" in
            lo|docker0|veth*|br-*|virbr*|tailscale*|zt*|wg*)
                continue
                ;;
        esac

        if [[ -e "$path/device" ]]; then
            printf '%s\n' "$iface"
            return 0
        fi
    done

    return 1
}

iface=$default_iface
if [[ -z "$iface" || ! -e "/sys/class/net/$iface" ]]; then
    iface=$(find_physical_iface || true)
fi

{
    printf 'server_id=%s\n' "$server_id"
    printf 'default_iface=%s\n' "$default_iface"
    printf 'detected_iface=%s\n' "$iface"
} > "$result_dir/context.env"

capture_cmd uname.txt uname -a
capture_sh sys-class-net.txt 'ls -l /sys/class/net'
capture_cmd ip-link.txt ip -br link
capture_cmd ip-addr.txt ip -br addr
capture_cmd ip-route.txt ip route
capture_cmd nmcli-device.txt nmcli device status
capture_cmd nmcli-connections.txt nmcli -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show
capture_cmd lsmod.txt lsmod
capture_sh lspci.txt 'lspci -nnk | grep -EA5 "Ethernet|Network"'
capture_sh journal-kernel.txt 'journalctl -b -k --no-pager | tail -n 200'
capture_sh journal-nm.txt 'journalctl -b -u NetworkManager --no-pager | tail -n 200'
capture_sh modprobe-config.txt 'grep -RHiEn "blacklist|r8168|r8169|bnx|tg3|e1000|ixgbe|igc|atlantic" /etc/modprobe.d /lib/modprobe.d 2>/dev/null || true'

if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then
    capture_cmd ethtool.txt ethtool "$iface"
    capture_sh driver.txt "readlink -f /sys/class/net/$iface/device/driver"
    capture_sh wakeup.txt "cat /sys/class/net/$iface/device/power/wakeup 2>/dev/null || true"
fi
