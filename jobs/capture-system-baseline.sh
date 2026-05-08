#!/usr/bin/env bash
set -euo pipefail

result_dir=${RIVULYA_TOOLKEY_RESULT_DIR:?missing RIVULYA_TOOLKEY_RESULT_DIR}
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

{
    printf 'server_id=%s\n' "$server_id"
    printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
} > "$result_dir/context.env"

capture_cmd uptime.txt uptime
capture_cmd uname.txt uname -a
capture_sh os-release.txt 'cat /etc/os-release 2>/dev/null || true'
capture_sh cmdline.txt 'cat /proc/cmdline 2>/dev/null || true'
capture_cmd disk-free.txt df -hT
capture_cmd mounts.txt findmnt
capture_cmd block-devices.txt lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MODEL,SERIAL,TRAN,MOUNTPOINTS
capture_sh usb-devices.txt 'lsusb 2>/dev/null || true'
capture_sh systemd-failed.txt 'systemctl --failed --no-pager 2>/dev/null || true'
capture_sh important-services.txt 'systemctl status NetworkManager systemd-networkd systemd-resolved ssh --no-pager 2>/dev/null || true'
capture_sh journal-priority.txt 'journalctl -b -p warning..alert --no-pager | tail -n 250'
capture_sh dmesg-tail.txt 'dmesg -T 2>/dev/null | tail -n 250 || dmesg 2>/dev/null | tail -n 250 || true'
capture_sh memory.txt 'free -h 2>/dev/null || true'
capture_sh processes.txt 'ps -eo pid,ppid,stat,comm,args --sort=comm | head -n 200'
