#!/usr/bin/env bash
set -euo pipefail

umask 077

log_tag="rivulya-toolkey"
config_file="/etc/rivulya-toolkey/device.env"
allowed_signers="/etc/rivulya-toolkey/allowed_signers"
state_root="/run/rivulya-toolkey"
mount_root="$state_root/mnt"
lock_file="$state_root/lock"
staging_root="$state_root/staging"
lock_acquired=0
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
common_lib=/usr/local/lib/rivulya-toolkey/toolkey-common.sh
if [[ ! -f "$common_lib" && -f "$script_dir/../lib/toolkey-common.sh" ]]; then
    common_lib="$script_dir/../lib/toolkey-common.sh"
fi
# shellcheck source=/dev/null
. "$common_lib"

log() {
    logger -t "$log_tag" -- "$*" || true
}

write_status() {
    local status_file=$1
    local status_value=$2
    local detail=$3
    {
        printf 'status=%s\n' "$status_value"
        printf 'detail=%s\n' "$detail"
        printf 'finished_at=%s\n' "$(date --iso-8601=seconds)"
    } > "$status_file"
}

cleanup() {
    sync || true
    if [[ $lock_acquired -eq 1 && -d "$staging_root" ]]; then
        rm -rf "$staging_root"
    fi
    if [[ -n ${current_staging_dir:-} && -d "$current_staging_dir" ]]; then
        rm -rf "$current_staging_dir"
    fi
    if [[ -n ${props_file:-} && -f "$props_file" ]]; then
        rm -f "$props_file"
    fi
    if [[ $lock_acquired -eq 1 ]] && mountpoint -q "$mount_root"; then
        umount "$mount_root" || true
    fi
}

trap cleanup EXIT

run_toolkey_job() {
    local timeout_sec=$1
    local interpreter=$2
    local entrypoint=$3
    local stdout_file=$4
    local stderr_file=$5
    local status=0

    timeout --preserve-status "$timeout_sec" "$interpreter" "$entrypoint" > "$stdout_file" 2> "$stderr_file" || status=$?
    return "$status"
}

hash_toolkey_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

verify_toolkey_hash() {
    local file=$1
    local expected=$2
    local actual

    actual=$(hash_toolkey_file "$file")
    [[ "$actual" == "$expected" ]]
}

if [[ ${RIVULYA_TOOLKEY_RUN_JOB_ONLY:-} == 1 ]]; then
    if [[ $# -ne 5 ]]; then
        echo "usage: RIVULYA_TOOLKEY_RUN_JOB_ONLY=1 $0 TIMEOUT INTERPRETER ENTRYPOINT STDOUT STDERR" >&2
        exit 2
    fi
    run_toolkey_job "$1" "$2" "$3" "$4" "$5"
    exit $?
fi

if [[ ${RIVULYA_TOOLKEY_HASH_FILE_ONLY:-} == 1 ]]; then
    if [[ $# -ne 1 ]]; then
        echo "usage: RIVULYA_TOOLKEY_HASH_FILE_ONLY=1 $0 FILE" >&2
        exit 2
    fi
    hash_toolkey_file "$1"
    exit 0
fi

if [[ ${RIVULYA_TOOLKEY_VERIFY_HASH_ONLY:-} == 1 ]]; then
    if [[ $# -ne 2 ]]; then
        echo "usage: RIVULYA_TOOLKEY_VERIFY_HASH_ONLY=1 $0 FILE EXPECTED_SHA256" >&2
        exit 2
    fi
    verify_toolkey_hash "$1" "$2"
    exit $?
fi

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /dev/sdXN" >&2
    exit 2
fi

device_path=$1

if [[ ! -f "$config_file" ]]; then
    echo "missing config: $config_file" >&2
    exit 1
fi

toolkey_load_env_file "$config_file" toolkey_validate_device_env_value

install -d -m 0755 "$state_root" "$mount_root"
exec 9>"$lock_file"
flock -n 9 || exit 0
lock_acquired=1
rm -rf "$staging_root"
install -d -m 0700 "$staging_root"

props_file=$(mktemp)
udevadm info --query=property --name="$device_path" > "$props_file"

get_prop() {
    local key=$1
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$props_file"
}

if [[ $(get_prop ID_VENDOR_ID) != "$USB_VENDOR_ID" ]]; then
    log "rejecting $device_path because vendor id does not match"
    exit 0
fi

if [[ $(get_prop ID_MODEL_ID) != "$USB_MODEL_ID" ]]; then
    log "rejecting $device_path because model id does not match"
    exit 0
fi

if [[ $(get_prop ID_SERIAL_SHORT) != "$USB_SERIAL_SHORT" ]]; then
    log "rejecting $device_path because serial does not match"
    exit 0
fi

if [[ $(get_prop ID_FS_UUID) != "$USB_FS_UUID" ]]; then
    log "rejecting $device_path because filesystem uuid does not match"
    exit 0
fi

mount -o rw,nosuid,nodev,noexec "$device_path" "$mount_root"

usb_root="$mount_root/rivulya-toolkey"
jobs_root="$usb_root/jobs"
results_root="$usb_root/results"
archive_root="$usb_root/archive"
state_dir="$usb_root/state"

for path in "$jobs_root" "$results_root" "$archive_root" "$state_dir"; do
    if [[ ! -d "$path" ]]; then
        log "missing expected path on tool key: $path"
        exit 1
    fi
done

shopt -s nullglob
processed_any=0
target_mismatch_seen=0

for job_dir in "$jobs_root"/*; do
    [[ -d "$job_dir" ]] || continue

    job_id=$(basename -- "$job_dir")
    result_dir="$results_root/$job_id"
    archive_dir="$archive_root/$job_id"
    status_file="$result_dir/status.env"

    install -d -m 0755 "$result_dir"

    manifest="$job_dir/manifest.env"
    signature="$job_dir/manifest.sig"
    current_staging_dir="$staging_root/$job_id"
    rm -rf "$current_staging_dir"
    install -d -m 0700 "$current_staging_dir"
    staged_manifest="$current_staging_dir/manifest.env"
    staged_signature="$current_staging_dir/manifest.sig"

    if [[ ! -f "$manifest" || ! -f "$signature" ]]; then
        write_status "$status_file" error "missing manifest or signature"
        mv "$job_dir" "$archive_dir.malformed.$(date +%s)" || true
        processed_any=1
        continue
    fi

    cp -- "$manifest" "$staged_manifest"
    cp -- "$signature" "$staged_signature"

    if ! ssh-keygen -Y verify -f "$allowed_signers" -I "$JOB_SIGNING_PRINCIPAL" -n file -s "$staged_signature" < "$staged_manifest" > "$result_dir/signature.log" 2>&1; then
        write_status "$status_file" error "signature verification failed"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    if ! toolkey_validate_env_file "$staged_manifest" toolkey_validate_manifest_value > "$result_dir/manifest.log" 2>&1; then
        write_status "$status_file" error "manifest validation failed"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    unset JOB_ID ENTRYPOINT INTERPRETER TIMEOUT_SEC JOB_SHA256 DESCRIPTION TARGET_SERVER_ID
    toolkey_load_env_file "$staged_manifest" toolkey_validate_manifest_value

    JOB_ID=${JOB_ID:-$job_id}
    ENTRYPOINT=${ENTRYPOINT:-job.sh}
    INTERPRETER=${INTERPRETER:-/bin/bash}
    TIMEOUT_SEC=${TIMEOUT_SEC:-600}
    JOB_SHA256=${JOB_SHA256:-}

    if [[ -z "$JOB_SHA256" ]]; then
        write_status "$status_file" error "missing signed job hash"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    if [[ -n ${TARGET_SERVER_ID:-} && -n ${SERVER_ID:-} && "$TARGET_SERVER_ID" != "$SERVER_ID" ]]; then
        log "skipping $job_id because target server id $TARGET_SERVER_ID does not match server $SERVER_ID"
        target_mismatch_seen=1
        continue
    fi

    if [[ ! "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
        write_status "$status_file" error "timeout is not a positive integer: $TIMEOUT_SEC"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    case "$INTERPRETER" in
        /bin/bash|/bin/sh|/usr/bin/python3)
            ;;
        *)
            write_status "$status_file" error "interpreter not allowed: $INTERPRETER"
            mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
            processed_any=1
            continue
            ;;
    esac

    entrypoint_path="$job_dir/$ENTRYPOINT"
    if [[ ! -f "$entrypoint_path" || -L "$entrypoint_path" ]]; then
        write_status "$status_file" error "entrypoint is missing or is a symlink"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    staged_entrypoint="$current_staging_dir/$ENTRYPOINT"
    cp -- "$entrypoint_path" "$staged_entrypoint"
    chmod 0500 "$staged_entrypoint"
    actual_sha256=$(hash_toolkey_file "$staged_entrypoint")
    {
        printf 'expected_sha256=%s\n' "$JOB_SHA256"
        printf 'actual_sha256=%s\n' "$actual_sha256"
    } > "$result_dir/checksums.log"
    if ! verify_toolkey_hash "$staged_entrypoint" "$JOB_SHA256"; then
        write_status "$status_file" error "signed job hash verification failed"
        mv "$job_dir" "$archive_dir.rejected.$(date +%s)" || true
        processed_any=1
        continue
    fi

    {
        printf 'job_id=%s\n' "$JOB_ID"
        printf 'description=%s\n' "${DESCRIPTION:-}"
        printf 'target_server_id=%s\n' "${TARGET_SERVER_ID:-}"
        printf 'server_id=%s\n' "${SERVER_ID:-}"
        printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'device=%s\n' "$device_path"
        printf 'kernel=%s\n' "$(uname -r)"
    } > "$result_dir/meta.env"

    if PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        RIVULYA_TOOLKEY_ROOT="$usb_root" \
        RIVULYA_TOOLKEY_JOB_ID="$JOB_ID" \
        RIVULYA_TOOLKEY_RESULT_DIR="$result_dir" \
        RIVULYA_TOOLKEY_SERVER_ID="${SERVER_ID:-}" \
        RIVULYA_TOOLKEY_DEFAULT_INTERFACE="${DEFAULT_INTERFACE:-}" \
        run_toolkey_job "$TIMEOUT_SEC" "$INTERPRETER" "$staged_entrypoint" "$result_dir/stdout.txt" "$result_dir/stderr.txt"; then
        exit_code=0
    else
        exit_code=$?
    fi

    {
        printf 'exit_code=%s\n' "$exit_code"
        printf 'finished_at=%s\n' "$(date --iso-8601=seconds)"
    } >> "$result_dir/meta.env"

    if [[ $exit_code -eq 0 ]]; then
        write_status "$status_file" ok "job completed successfully"
        mv "$job_dir" "$archive_dir"
    else
        write_status "$status_file" error "job exited with code $exit_code"
        mv "$job_dir" "$archive_dir.failed.$(date +%s)" || true
    fi

    processed_any=1
    rm -rf "$current_staging_dir"
    current_staging_dir=
done

if [[ $processed_any -eq 1 ]]; then
    printf 'last_run=%s\nstatus=processed\n' "$(date --iso-8601=seconds)" > "$state_dir/last-run.env"
    /usr/local/lib/rivulya-toolkey/signal.sh "${DEFAULT_INTERFACE:-}" || true
elif [[ $target_mismatch_seen -eq 1 ]]; then
    {
        printf 'last_run=%s\n' "$(date --iso-8601=seconds)"
        printf 'status=target_mismatch\n'
        printf 'server_id=%s\n' "${SERVER_ID:-}"
    } > "$state_dir/last-run.env"
else
    printf 'last_run=%s\nstatus=no_jobs\n' "$(date --iso-8601=seconds)" > "$state_dir/last-run.env"
fi
