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
    lsblk -lno PATH,LABEL | awk -v wanted="$toolkey_label" '$2 == wanted { print $1; exit }'
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

summary_value() {
    local file=$1
    local key=$2

    sudo awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$file" 2>/dev/null || true
}

print_bootstrap_summary() {
    local result_dir=$1
    local summary_file="$result_dir/bootstrap-self-test-summary.env"
    local checks_file="$result_dir/bootstrap-self-test-checks.txt"
    local bootstrap_status hostname server_id kernel ok_count issue_count

    [[ -f "$summary_file" ]] || return 0

    bootstrap_status=$(summary_value "$summary_file" status)
    hostname=$(summary_value "$summary_file" hostname)
    server_id=$(summary_value "$summary_file" server_id)
    kernel=$(summary_value "$summary_file" kernel)
    ok_count=$(sudo awk '/^ok / { count++ } END { print count + 0 }' "$checks_file" 2>/dev/null)
    issue_count=$(sudo awk '!/^ok / { count++ } END { print count + 0 }' "$checks_file" 2>/dev/null)

    echo "--- bootstrap summary"
    if [[ "$bootstrap_status" == 0 ]]; then
        echo "bootstrap_self_test=PASS"
    else
        echo "bootstrap_self_test=FAIL"
    fi
    echo "server_id=${server_id:-}"
    echo "hostname=${hostname:-}"
    echo "kernel=${kernel:-}"
    echo "checks_ok=${ok_count:-0}"
    echo "checks_with_issues=${issue_count:-0}"
    if [[ ${issue_count:-0} -gt 0 ]]; then
        echo "issues:"
        sudo awk '!/^ok / { print "  " $0 }' "$checks_file" 2>/dev/null || true
    fi
}

print_result_summary() {
    local result_dir=$1
    local status_file="$result_dir/status.env"
    local meta_file="$result_dir/meta.env"
    local status detail description job_id server_id target_server_id exit_code

    status=$(summary_value "$status_file" status)
    detail=$(summary_value "$status_file" detail)
    description=$(summary_value "$meta_file" description)
    job_id=$(summary_value "$meta_file" job_id)
    server_id=$(summary_value "$meta_file" server_id)
    target_server_id=$(summary_value "$meta_file" target_server_id)
    exit_code=$(summary_value "$meta_file" exit_code)

    echo "--- summary"
    echo "job_id=${job_id:-}"
    echo "description=${description:-}"
    echo "status=${status:-unknown}"
    echo "detail=${detail:-}"
    echo "exit_code=${exit_code:-}"
    echo "server_id=${server_id:-}"
    echo "target_server_id=${target_server_id:-<any trusted server>}"

    print_bootstrap_summary "$result_dir"
}

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

print_result_summary "$result_dir"

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
