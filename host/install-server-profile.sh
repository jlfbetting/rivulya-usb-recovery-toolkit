#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/rivulya-toolkey/profiles/SERVER_ID" >&2
    exit 2
fi

profile_dir=$(readlink -f -- "$1")
profile_name=$(basename -- "$profile_dir")
usb_root=$(CDPATH= cd -- "$profile_dir/../.." && pwd)

config_dir="$profile_dir/config"
common_dir="$usb_root/common"
host_dir="$usb_root/host"

device_env_src="$config_dir/device.env"
allowed_signers_src="$common_dir/allowed_signers"
common_lib_src="$common_dir/toolkey-common.sh"
service_src="$host_dir/rivulya-toolkey@.service"
runner_src="$host_dir/runner.sh"
signal_src="$host_dir/signal.sh"

for path in "$device_env_src" "$allowed_signers_src" "$common_lib_src" "$service_src" "$runner_src" "$signal_src"; do
    if [[ ! -f "$path" ]]; then
        echo "Missing required file: $path" >&2
        exit 1
    fi
done

# shellcheck source=/dev/null
. "$common_lib_src"

toolkey_load_env_file "$device_env_src" toolkey_validate_device_env_value

required_vars=(
    SERVER_ID
    USB_VENDOR_ID
    USB_MODEL_ID
    USB_SERIAL_SHORT
    USB_FS_UUID
    USB_LABEL
    JOB_SIGNING_PRINCIPAL
)

for var_name in "${required_vars[@]}"; do
    if [[ -z ${!var_name:-} ]]; then
        echo "Missing required config variable: $var_name" >&2
        exit 1
    fi
done

install -d -m 0755 /etc/rivulya-toolkey /usr/local/lib/rivulya-toolkey
install -m 0644 "$device_env_src" /etc/rivulya-toolkey/device.env
install -m 0644 "$allowed_signers_src" /etc/rivulya-toolkey/allowed_signers
install -m 0644 "$common_lib_src" /usr/local/lib/rivulya-toolkey/toolkey-common.sh
install -m 0755 "$runner_src" /usr/local/lib/rivulya-toolkey/runner.sh
install -m 0755 "$signal_src" /usr/local/lib/rivulya-toolkey/signal.sh
install -m 0644 "$service_src" /etc/systemd/system/rivulya-toolkey@.service

cat > /etc/udev/rules.d/99-rivulya-toolkey.rules <<EOF
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_BUS}=="usb", ENV{ID_VENDOR_ID}=="$USB_VENDOR_ID", ENV{ID_MODEL_ID}=="$USB_MODEL_ID", ENV{ID_SERIAL_SHORT}=="$USB_SERIAL_SHORT", ENV{ID_FS_UUID}=="$USB_FS_UUID", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rivulya-toolkey@%k.service"
EOF

modprobe pcspkr >/dev/null 2>&1 || true
systemctl daemon-reload
udevadm control --reload

cat <<EOF
Installed Rivulya USB recovery support for server profile: $profile_name

Trusted USB device:
  vendor_id:      $USB_VENDOR_ID
  model_id:       $USB_MODEL_ID
  serial_short:   $USB_SERIAL_SHORT
  fs_uuid:        $USB_FS_UUID
  label:          $USB_LABEL
  signing name:   $JOB_SIGNING_PRINCIPAL
  server_id:      $SERVER_ID
  default_iface:  ${DEFAULT_INTERFACE:-}

The service will trigger automatically when that exact USB partition is inserted.
EOF
