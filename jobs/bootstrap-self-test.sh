#!/usr/bin/env bash
set -euo pipefail

result_dir=${RIVULYA_TOOLKEY_RESULT_DIR:?missing RIVULYA_TOOLKEY_RESULT_DIR}
toolkey_root=${RIVULYA_TOOLKEY_ROOT:?missing RIVULYA_TOOLKEY_ROOT}
server_id=${RIVULYA_TOOLKEY_SERVER_ID:-}
default_iface=${RIVULYA_TOOLKEY_DEFAULT_INTERFACE:-}
captured_at=$(date --iso-8601=seconds)
hostname_value=$(hostname 2>/dev/null || uname -n)
checks_file="$result_dir/bootstrap-self-test-checks.txt"
summary_file="$result_dir/bootstrap-self-test-summary.env"
status=0

record_check() {
    local label=$1
    local path=$2

    if [[ -e "$path" ]]; then
        printf 'ok %s %s\n' "$label" "$path" >> "$checks_file"
    else
        printf 'missing %s %s\n' "$label" "$path" >> "$checks_file"
        status=1
    fi
}

record_layout_check() {
    local name=$1
    local path=$2

    if [[ -d "$path" ]]; then
        printf 'ok layout %s %s\n' "$name" "$path" >> "$checks_file"
    else
        printf 'missing layout %s %s\n' "$name" "$path" >> "$checks_file"
        status=1
    fi
}

{
    printf 'server_id=%s\n' "$server_id"
    printf 'hostname=%s\n' "$hostname_value"
    printf 'captured_at=%s\n' "$captured_at"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'default_interface=%s\n' "$default_iface"
    printf 'toolkey_root=%s\n' "$toolkey_root"
    printf 'result_dir=%s\n' "$result_dir"
} > "$summary_file"

: > "$checks_file"

record_check device_env /etc/rivulya-toolkey/device.env
record_check allowed_signers /etc/rivulya-toolkey/allowed_signers
record_check systemd_unit /etc/systemd/system/rivulya-toolkey@.service
record_check udev_rule /etc/udev/rules.d/99-rivulya-toolkey.rules
record_check runner /usr/local/lib/rivulya-toolkey/runner.sh
record_check signal /usr/local/lib/rivulya-toolkey/signal.sh
record_check common_lib /usr/local/lib/rivulya-toolkey/toolkey-common.sh

record_layout_check jobs "$toolkey_root/jobs"
record_layout_check results "$toolkey_root/results"
record_layout_check archive "$toolkey_root/archive"
record_layout_check state "$toolkey_root/state"

if [[ "$result_dir" == "$toolkey_root/results/"* ]]; then
    printf 'ok result_dir %s\n' "$result_dir" >> "$checks_file"
else
    printf 'unexpected result_dir %s\n' "$result_dir" >> "$checks_file"
    status=1
fi

systemctl list-unit-files rivulya-toolkey@.service --no-pager --no-legend > "$result_dir/bootstrap-self-test-systemd.txt" 2>&1 || true
cat /etc/udev/rules.d/99-rivulya-toolkey.rules > "$result_dir/bootstrap-self-test-udev-rule.txt" 2>/dev/null || true
find "$toolkey_root" -maxdepth 2 -mindepth 1 \( -type d -o -type f \) | sort > "$result_dir/bootstrap-self-test-toolkey-layout.txt" 2>/dev/null || true

printf 'status=%s\n' "$status" >> "$summary_file"
if [[ $status -ne 0 ]]; then
    exit $status
fi