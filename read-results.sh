#!/usr/bin/env bash
set -euo pipefail

job_id=${1:-}
kit_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/toolkey-common.sh
. "$kit_root/lib/toolkey-common.sh"
owner_user=${SUDO_USER:-$USER}
owner_home=$(getent passwd "$owner_user" | cut -d: -f6)
mount_point=${TOOLKEY_MOUNT:-$owner_home/rivulya-toolkey-mount}
toolkey_label=${TOOLKEY_LABEL:-RIVULYA_TOOLKEY}
toolkey_validate_label "$toolkey_label"

find_toolkey_part() {
    lsblk -rno PATH,LABEL | awk -v wanted="$toolkey_label" '$2 == wanted { print $1; exit }'
}

toolkey_part=${TOOLKEY_PART:-$(find_toolkey_part)}
if [[ -z "$toolkey_part" || ! -e "$toolkey_part" ]]; then
    echo "trusted tool key partition not present for label $toolkey_label" >&2
    exit 1
fi

install -d -m 0755 "$mount_point"
mounted_here=0
if ! mountpoint -q "$mount_point"; then
    sudo mount "$toolkey_part" "$mount_point"
    mounted_here=1
fi

cleanup() {
    if [[ $mounted_here -eq 1 ]]; then
        sudo umount "$mount_point" || true
    fi
}
trap cleanup EXIT

results_root="$mount_point/rivulya-toolkey/results"
state_file="$mount_point/rivulya-toolkey/state/last-run.env"

if [[ ! -d "$results_root" ]]; then
    echo "tool key layout not initialized: $results_root" >&2
    exit 1
fi

if [[ -z "$job_id" ]]; then
    mapfile -t result_dirs < <(find "$results_root" -mindepth 1 -maxdepth 1 -type d | sort)
    if [[ ${#result_dirs[@]} -eq 0 ]]; then
        echo "no result directories present"
        if [[ -f "$state_file" ]]; then
            echo "--- state"
            sudo sed -n '1,40p' "$state_file"
        fi
        exit 0
    fi
    result_dir=${result_dirs[-1]}
else
    result_dir="$results_root/$job_id"
    if [[ ! -d "$result_dir" ]]; then
        echo "result directory not found: $result_dir" >&2
        exit 1
    fi
fi

echo "Result directory: $result_dir"
if [[ -f "$state_file" ]]; then
    echo "--- state"
    sudo sed -n '1,40p' "$state_file"
fi

echo "--- status"
sudo sed -n '1,40p' "$result_dir/status.env" 2>/dev/null || echo "missing status.env"
echo "--- meta"
sudo sed -n '1,80p' "$result_dir/meta.env" 2>/dev/null || echo "missing meta.env"
echo "--- files"
sudo find "$result_dir" -maxdepth 1 -type f | sort

echo "--- stdout"
sudo sed -n '1,160p' "$result_dir/stdout.txt" 2>/dev/null || true
echo "--- stderr"
sudo sed -n '1,160p' "$result_dir/stderr.txt" 2>/dev/null || true
