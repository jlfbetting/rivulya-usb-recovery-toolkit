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
label_default=${TOOLKEY_LABEL:-RIVULYA_TOOLKEY}

find_toolkey_part() {
    local label=$1
    lsblk -rno PATH,LABEL | awk -v wanted="$label" '$2 == wanted { print $1; exit }'
}

write_profile_bundle() {
    local mount_point=$1
    local server_id=$2
    local default_iface=$3
    local owner_user=$4
    local usb_label=$5
    local fs_uuid=$6
    local vendor_id=$7
    local model_id=$8
    local serial_short=$9
    local job_principal=${10}

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
     sudo bash /mnt/rivulya-toolkey/rivulya-toolkey/profiles/$server_id/install-on-server.sh
     sudo umount /mnt/rivulya-toolkey
3. Reinsert the stick once to confirm the service triggers.

After bootstrap, use this stick from the operator machine:
- Queue signed jobs with:
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

read -r -p "Mount point [$mount_point_default]: " mount_point
mount_point=${mount_point:-$mount_point_default}
read -r -p "Toolkey label [$label_default]: " label
label=${label:-$label_default}
toolkey_validate_label "$label"

toolkey_part=${TOOLKEY_PART:-$(find_toolkey_part "$label")}
if [[ -z "$toolkey_part" ]]; then
    echo "Could not find a mounted or attached toolkey partition with label $label" >&2
    exit 1
fi

install -d -m 0755 "$mount_point"
mounted_here=0
if ! mountpoint -q "$mount_point"; then
    mount "$toolkey_part" "$mount_point"
    mounted_here=1
fi

cleanup() {
    if [[ $mounted_here -eq 1 ]]; then
        umount "$mount_point" || true
    fi
}
trap cleanup EXIT

stick_env="$mount_point/rivulya-toolkey/common/stick.env"
if [[ ! -f "$stick_env" ]]; then
    echo "Stick metadata not found: $stick_env" >&2
    exit 1
fi

toolkey_load_env_file "$stick_env" toolkey_validate_device_env_value

while true; do
    read -r -p "Server ID (blank to finish): " server_id_raw
    [[ -z "$server_id_raw" ]] && break
    server_id=$(toolkey_sanitize_id "$server_id_raw")
    if [[ -z "$server_id" ]]; then
        echo "Server ID must contain at least one letter or number." >&2
        continue
    fi
    toolkey_validate_server_id "$server_id"

    profile_dir="$mount_point/rivulya-toolkey/profiles/$server_id"
    if [[ -d "$profile_dir" ]]; then
        read -r -p "Profile $server_id already exists. Overwrite it? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || continue
        rm -rf "$profile_dir"
    fi

    read -r -p "Primary interface on $server_id [enp1s0]: " default_iface
    default_iface=${default_iface:-enp1s0}
    toolkey_validate_iface "$default_iface"

    write_profile_bundle "$mount_point" "$server_id" "$default_iface" "$owner_user" "$USB_LABEL" "$USB_FS_UUID" "$USB_VENDOR_ID" "$USB_MODEL_ID" "$USB_SERIAL_SHORT" "$JOB_SIGNING_PRINCIPAL"
    echo "Created profile bundle: $profile_dir"

done

sync
