#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 SCRIPT_FILE [description] [timeout_sec] [target_server_id]" >&2
    exit 2
fi

kit_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/toolkey-common.sh
. "$kit_root/lib/toolkey-common.sh"
owner_user=${SUDO_USER:-$USER}
owner_home=$(getent passwd "$owner_user" | cut -d: -f6)
script_file=$(readlink -f -- "$1")
description=${2:-manual job}
timeout_sec=${3:-600}
target_server_id=${4:-${TARGET_SERVER_ID:-}}
mount_point=${TOOLKEY_MOUNT:-$owner_home/rivulya-toolkey-mount}
key_path=${TOOLKEY_SIGNING_KEY:-$owner_home/.ssh/rivulya_toolkey_signing}
toolkey_label=${TOOLKEY_LABEL:-RIVULYA_TOOLKEY}
toolkey_validate_label "$toolkey_label"
toolkey_validate_manifest_value DESCRIPTION "$description"
toolkey_require_match "timeout" "$timeout_sec" '^[0-9]{1,6}$'
if [[ -n "$target_server_id" ]]; then
    toolkey_validate_server_id "$target_server_id"
fi

find_toolkey_part() {
    lsblk -rno PATH,LABEL | awk -v wanted="$toolkey_label" '$2 == wanted { print $1; exit }'
}

toolkey_part=${TOOLKEY_PART:-$(find_toolkey_part)}

if [[ ! -f "$script_file" ]]; then
    echo "script file not found: $script_file" >&2
    exit 1
fi

if [[ -z "$toolkey_part" || ! -e "$toolkey_part" ]]; then
    echo "trusted tool key partition not present for label $toolkey_label" >&2
    exit 1
fi

if [[ ! -f "$key_path" ]]; then
    echo "missing signing key: $key_path" >&2
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

usb_root="$mount_point/rivulya-toolkey"
jobs_root="$usb_root/jobs"

if [[ ! -d "$jobs_root" ]]; then
    echo "tool key layout not initialized: $jobs_root" >&2
    exit 1
fi

job_id="job-$(date +%Y%m%d-%H%M%S)-$$"
job_dir="$jobs_root/$job_id"
install -d -m 0755 "$job_dir"
install -m 0644 "$script_file" "$job_dir/job.sh"
job_sha256=$(sha256sum "$job_dir/job.sh" | awk '{ print $1 }')

{
    toolkey_write_env_line JOB_ID "$job_id"
    toolkey_write_env_line DESCRIPTION "$description"
    toolkey_write_env_line ENTRYPOINT job.sh
    toolkey_write_env_line INTERPRETER /bin/bash
    toolkey_write_env_line TIMEOUT_SEC "$timeout_sec"
    toolkey_write_env_line JOB_SHA256 "$job_sha256"
    if [[ -n "$target_server_id" ]]; then
        toolkey_write_env_line TARGET_SERVER_ID "$target_server_id"
    fi
} > "$job_dir/manifest.env"

printf '%s  job.sh\n' "$job_sha256" > "$job_dir/checksums.txt"
ssh-keygen -Y sign -f "$key_path" -n file "$job_dir/manifest.env" >/dev/null
mv "$job_dir/manifest.env.sig" "$job_dir/manifest.sig"

sync

echo "Queued $job_id"
echo "  script:           $script_file"
echo "  description:      $description"
echo "  timeout:          $timeout_sec"
echo "  target_server_id: ${target_server_id:-<any trusted server>}"
echo "  path:             $job_dir"
