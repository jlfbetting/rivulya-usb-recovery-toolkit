#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo --preserve-env=HOME,USER -- "$0" "$@"
fi

kit_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/toolkey-common.sh
. "$kit_root/lib/toolkey-common.sh"
owner_user=${SUDO_USER:-$USER}
owner_home=$(getent passwd "$owner_user" | cut -d: -f6)
mount_point_default=${TOOLKEY_MOUNT:-$owner_home/rivulya-toolkey-mount}
usb_label_default=${TOOLKEY_LABEL:-RIVULYA_TOOLKEY}
job_principal=${JOB_SIGNING_PRINCIPAL:-rivulya-toolkey}
key_path_default=${TOOLKEY_SIGNING_KEY:-$owner_home/.ssh/rivulya_toolkey_signing}
bootstrap_self_test_timeout=${BOOTSTRAP_SELF_TEST_TIMEOUT_SEC:-180}
bootstrap_self_test_script="$kit_root/jobs/bootstrap-self-test.sh"

require_tools() {
    local required
    for required in awk blkid findmnt grep install lsblk mkfs.ext4 mount partprobe sfdisk sha256sum ssh-keygen sync udevadm umount wipefs; do
        command -v "$required" >/dev/null 2>&1 || {
            echo "Missing required tool: $required" >&2
            exit 1
        }
    done
}

partition_path_for_disk() {
    local disk=$1
    local part
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        udevadm settle >/dev/null 2>&1 || true
        part=$(lsblk -lno PATH,TYPE "$disk" | awk '$2 == "part" { print $1; exit }')
        if [[ -n "$part" ]]; then
            printf '%s\n' "$part"
            return 0
        fi
    done
    return 1
}

list_usb_disks() {
    lsblk -dno PATH,TRAN,SIZE,MODEL,SERIAL | awk '$2 == "usb" { $1=$1; print }'
}

write_bootstrap_launcher() {
    local mount_point=$1
    local owner_user=$2

    cat > "$mount_point/BOOTSTRAP-ON-SERVER.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
profiles_root="$script_dir/rivulya-toolkey/profiles"

usage() {
    cat <<USAGE
usage: $0 [server_id]

Run this after mounting the Rivulya USB stick on the target server.

- If the stick contains exactly one server profile, the argument is optional.
- If the stick contains multiple server profiles, pass the intended server_id.

Examples:
  sudo bash /mnt/rivulya-toolkey/BOOTSTRAP-ON-SERVER.sh
  sudo bash /mnt/rivulya-toolkey/BOOTSTRAP-ON-SERVER.sh edge-node-01
USAGE
}

[[ -d "$profiles_root" ]] || {
    echo "Profiles directory not found: $profiles_root" >&2
    exit 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

shopt -s nullglob
profiles=()
for path in "$profiles_root"/*; do
    [[ -d "$path" ]] || continue
    profiles+=("$(basename -- "$path")")
done
shopt -u nullglob

if [[ ${#profiles[@]} -eq 0 ]]; then
    echo "No server profiles were found on this stick." >&2
    exit 1
fi

server_id=${1:-}
if [[ -z "$server_id" ]]; then
    if [[ ${#profiles[@]} -eq 1 ]]; then
        server_id=${profiles[0]}
    else
        echo "Multiple server profiles are available on this stick:" >&2
        printf '  %s\n' "${profiles[@]}" >&2
        echo >&2
        usage >&2
        exit 2
    fi
fi

profile_script="$profiles_root/$server_id/install-on-server.sh"
if [[ ! -f "$profile_script" ]]; then
    echo "Server profile not found: $server_id" >&2
    echo "Available profiles:" >&2
    printf '  %s\n' "${profiles[@]}" >&2
    exit 1
fi

exec bash "$profile_script"
EOF

    chmod 0755 "$mount_point/BOOTSTRAP-ON-SERVER.sh"
    chown "$owner_user":"$owner_user" "$mount_point/BOOTSTRAP-ON-SERVER.sh"
}

write_profile_bundle() {
    local mount_point=$1
    local server_id=$2
    local default_iface=$3
    local usb_label=$4
    local fs_uuid=$5
    local vendor_id=$6
    local model_id=$7
    local serial_short=$8
    local job_principal=$9
    local owner_user=${10}

    local profile_dir="$mount_point/rivulya-toolkey/profiles/$server_id"
    install -d -m 0755 "$profile_dir/config"

    toolkey_validate_server_id "$server_id"
    toolkey_validate_label "$usb_label"
    toolkey_validate_device_env_value USB_VENDOR_ID "$vendor_id"
    toolkey_validate_device_env_value USB_MODEL_ID "$model_id"
    toolkey_validate_device_env_value USB_SERIAL_SHORT "$serial_short"
    toolkey_validate_device_env_value USB_FS_UUID "$fs_uuid"
    toolkey_validate_principal "$job_principal"
    toolkey_validate_iface "$default_iface"

    {
        toolkey_write_env_line SERVER_ID "$server_id"
        toolkey_write_env_line USB_VENDOR_ID "$vendor_id"
        toolkey_write_env_line USB_MODEL_ID "$model_id"
        toolkey_write_env_line USB_SERIAL_SHORT "$serial_short"
        toolkey_write_env_line USB_FS_UUID "$fs_uuid"
        toolkey_write_env_line USB_LABEL "$usb_label"
        toolkey_write_env_line JOB_SIGNING_PRINCIPAL "$job_principal"
        toolkey_write_env_line DEFAULT_INTERFACE "$default_iface"
    } > "$profile_dir/config/device.env"

    cat > "$profile_dir/install-on-server.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
script_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
usb_root=\$(CDPATH= cd -- "\$script_dir/../.." && pwd)
exec "\$usb_root/host/install-server-profile.sh" "\$script_dir"
EOF
    chmod 0755 "$profile_dir/install-on-server.sh"

    cat > "$profile_dir/SERVER-SETUP.txt" <<EOF
Rivulya USB recovery bootstrap for server profile: $server_id

This file is a reference copy. After mounting the stick on the server, the
primary entrypoint is:

    sudo bash /mnt/rivulya-toolkey/BOOTSTRAP-ON-SERVER.sh $server_id

Trusted USB stick identity:
  vendor_id:    $vendor_id
  model_id:     $model_id
  serial_short: $serial_short
  fs_uuid:      $fs_uuid
  label:        $usb_label

One-time setup on the Ubuntu server:
1. Insert this USB stick into the server.
2. From a local console on the server, run:
     sudo mkdir -p /mnt/rivulya-toolkey
     sudo mount UUID=$fs_uuid /mnt/rivulya-toolkey
    sudo bash /mnt/rivulya-toolkey/BOOTSTRAP-ON-SERVER.sh $server_id
     sudo umount /mnt/rivulya-toolkey
3. Reinsert the stick once. The server will automatically run the queued bootstrap self-test for $server_id.
4. Move the stick back to the operator machine and run:
    cd /path/to/rivulya-usb-recovery-toolkit
    bash ./read-results.sh
   Confirm that the latest result bundle is the bootstrap self-test for $server_id and completed successfully before relying on the toolkit for recovery work.

After the bootstrap self-test passes, use this stick from the operator machine:
- Queue signed jobs with:
    cd /path/to/rivulya-usb-recovery-toolkit
    bash ./queue-job.sh JOB_SCRIPT "description" 600
- Or target this specific server explicitly:
    cd /path/to/rivulya-usb-recovery-toolkit
    bash ./queue-job.sh JOB_SCRIPT "description" 600 $server_id
- Read the latest results with:
    cd /path/to/rivulya-usb-recovery-toolkit
    bash ./read-results.sh

Server-specific defaults:
  server_id:     $server_id
  default_iface: $default_iface

Notes:
- This server will trust only this exact USB stick because the udev rule matches the USB identity and filesystem UUID.
- The same stick can be enrolled on other servers too, but always target jobs with the matching server_id.
EOF

    chown -R "$owner_user":"$owner_user" "$profile_dir"
}

require_tools

mapfile -t usb_candidates < <(list_usb_disks)
if [[ ${#usb_candidates[@]} -eq 0 ]]; then
    echo "No attached USB mass-storage disks were found." >&2
    exit 1
fi

echo "Available USB disks:"
for i in "${!usb_candidates[@]}"; do
    printf '  [%d] %s\n' "$((i + 1))" "${usb_candidates[i]}"
done

disk_index=
while [[ -z "$disk_index" ]]; do
    read -r -p "Select the USB disk to erase and initialize: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#usb_candidates[@]} )); then
        disk_index=$((reply - 1))
    else
        echo "Enter a number from the list above." >&2
    fi
done

disk_device=$(awk '{print $1}' <<<"${usb_candidates[disk_index]}")
read -r -p "Mount point [$mount_point_default]: " mount_point
mount_point=${mount_point:-$mount_point_default}
read -r -p "Filesystem label [$usb_label_default]: " usb_label
usb_label=${usb_label:-$usb_label_default}
toolkey_validate_label "$usb_label"
read -r -p "Signing key path [$key_path_default]: " key_path
key_path=${key_path:-$key_path_default}
toolkey_validate_principal "$job_principal"

echo
echo "Selected disk: $disk_device"
echo "This will destroy all data on the entire disk."
read -r -p "Type YES to continue: " confirmation
if [[ "$confirmation" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

install -d -m 0700 "$owner_home/.ssh"
chown "$owner_user":"$owner_user" "$owner_home/.ssh"
if [[ ! -f "$key_path" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$job_principal" -f "$key_path"
fi
chown "$owner_user":"$owner_user" "$key_path" "$key_path.pub"

while read -r part_path; do
    [[ "$part_path" == "$disk_device" ]] && continue
    umount "$part_path" >/dev/null 2>&1 || true
done < <(lsblk -lno PATH "$disk_device")

wipefs -a "$disk_device"
printf 'label: gpt\n, ,L\n' | sfdisk "$disk_device" >/dev/null
partprobe "$disk_device" >/dev/null 2>&1 || true
part_device=$(partition_path_for_disk "$disk_device") || {
    echo "Could not determine the new partition for $disk_device" >&2
    exit 1
}

mkfs.ext4 -F -L "$usb_label" "$part_device" >/dev/null
udevadm settle >/dev/null 2>&1 || true
fs_uuid=$(blkid -o value -s UUID "$part_device")

vendor_id=$(udevadm info --query=property --name="$disk_device" | awk -F= '$1 == "ID_VENDOR_ID" { print $2; exit }')
model_id=$(udevadm info --query=property --name="$disk_device" | awk -F= '$1 == "ID_MODEL_ID" { print $2; exit }')
serial_short=$(udevadm info --query=property --name="$disk_device" | awk -F= '$1 == "ID_SERIAL_SHORT" { print $2; exit }')
toolkey_validate_device_env_value USB_VENDOR_ID "$vendor_id"
toolkey_validate_device_env_value USB_MODEL_ID "$model_id"
toolkey_validate_device_env_value USB_SERIAL_SHORT "$serial_short"
toolkey_validate_device_env_value USB_FS_UUID "$fs_uuid"

install -d -m 0755 "$mount_point"
mount "$part_device" "$mount_point"
trap 'umount "$mount_point" >/dev/null 2>&1 || true' EXIT

install -d -m 0755 \
    "$mount_point/rivulya-toolkey/common" \
    "$mount_point/rivulya-toolkey/host" \
    "$mount_point/rivulya-toolkey/profiles" \
    "$mount_point/rivulya-toolkey/jobs" \
    "$mount_point/rivulya-toolkey/results" \
    "$mount_point/rivulya-toolkey/archive" \
    "$mount_point/rivulya-toolkey/state"

install -m 0755 "$kit_root/host/install-server-profile.sh" "$mount_point/rivulya-toolkey/host/install-server-profile.sh"
install -m 0755 "$kit_root/host/runner.sh" "$mount_point/rivulya-toolkey/host/runner.sh"
install -m 0755 "$kit_root/host/signal.sh" "$mount_point/rivulya-toolkey/host/signal.sh"
install -m 0755 "$kit_root/host/uninstall-server-profile.sh" "$mount_point/rivulya-toolkey/host/uninstall-server-profile.sh"
install -m 0644 "$kit_root/host/rivulya-toolkey@.service" "$mount_point/rivulya-toolkey/host/rivulya-toolkey@.service"
install -m 0644 "$kit_root/lib/toolkey-common.sh" "$mount_point/rivulya-toolkey/common/toolkey-common.sh"
write_bootstrap_launcher "$mount_point" "$owner_user"

{
    toolkey_write_env_line USB_VENDOR_ID "$vendor_id"
    toolkey_write_env_line USB_MODEL_ID "$model_id"
    toolkey_write_env_line USB_SERIAL_SHORT "$serial_short"
    toolkey_write_env_line USB_FS_UUID "$fs_uuid"
    toolkey_write_env_line USB_LABEL "$usb_label"
    toolkey_write_env_line JOB_SIGNING_PRINCIPAL "$job_principal"
} > "$mount_point/rivulya-toolkey/common/stick.env"

pubkey=$(cat "$key_path.pub")
printf '%s %s\n' "$job_principal" "$pubkey" > "$mount_point/rivulya-toolkey/common/allowed_signers"

cat > "$mount_point/README-FIRST.txt" <<EOF
Rivulya USB recovery toolkit

This stick is initialized and ready for one-time server bootstrap.

Trusted USB identity:
  vendor_id:    $vendor_id
  model_id:     $model_id
  serial_short: $serial_short
  fs_uuid:      $fs_uuid
  label:        $usb_label

Next steps:
1. Create one or more server profiles on this stick.
2. Each new server profile automatically queues a one-time bootstrap self-test job for that server.
3. On each target server, mount the stick with sudo, then run BOOTSTRAP-ON-SERVER.sh from the root of the mounted stick.
4. Reinsert the stick into that server once so the bootstrap self-test runs automatically.
5. Move the stick back to the operator machine and confirm the self-test result with read-results.sh before queuing other jobs.
EOF

profile_count=0
while true; do
    read -r -p "Create a server profile now? [Y/n]: " create_profile
    create_profile=${create_profile:-Y}
    [[ "$create_profile" =~ ^[Nn]$ ]] && break

    while true; do
        read -r -p "Server ID you choose for this server profile (used to target jobs, example: edge-node-01): " server_id_raw
        server_id=$(toolkey_sanitize_id "$server_id_raw")
        if [[ -n "$server_id" ]]; then
            toolkey_validate_server_id "$server_id"
            break
        fi
        echo "Server ID cannot be empty. Pick a stable label such as edge-node-01 or nas-01." >&2
    done

    read -r -p "Primary interface hint on $server_id for diagnostics and LED blink [enp1s0]: " default_iface
    default_iface=${default_iface:-enp1s0}
    toolkey_validate_iface "$default_iface"

    write_profile_bundle "$mount_point" "$server_id" "$default_iface" "$usb_label" "$fs_uuid" "$vendor_id" "$model_id" "$serial_short" "$job_principal" "$owner_user"
    bootstrap_job_dir=$(toolkey_queue_bootstrap_self_test_job "$mount_point/rivulya-toolkey/jobs" "$bootstrap_self_test_script" "$key_path" "$server_id" "$bootstrap_self_test_timeout")
    echo "Queued bootstrap self-test: $(basename -- "$bootstrap_job_dir")"
    profile_count=$((profile_count + 1))

    read -r -p "Add another server profile? [y/N]: " again
    [[ "$again" =~ ^[Yy]$ ]] || break
done

chown -R "$owner_user":"$owner_user" "$mount_point/rivulya-toolkey" "$mount_point/README-FIRST.txt" "$mount_point/BOOTSTRAP-ON-SERVER.sh"
sync

echo
echo "Rivulya USB recovery stick initialized."
echo "  disk:          $disk_device"
echo "  partition:     $part_device"
echo "  mounted at:    $mount_point"
echo "  fs_uuid:       $fs_uuid"
echo "  signing key:   $key_path"
echo "  profiles:      $profile_count"
echo
if [[ $profile_count -eq 0 ]]; then
    echo "No server profiles were created yet. Run:"
    echo "  sudo bash $kit_root/add-server-profile.sh"
fi
