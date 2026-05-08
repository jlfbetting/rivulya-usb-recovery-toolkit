#!/usr/bin/env bash

toolkey_die() {
    echo "$*" >&2
    exit 1
}

toolkey_sanitize_id() {
    local raw=$1
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    raw=$(printf '%s' "$raw" | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
    printf '%s\n' "$raw"
}

toolkey_require_match() {
    local name=$1
    local value=$2
    local regex=$3
    [[ "$value" =~ $regex ]] || toolkey_die "Invalid $name: $value"
}

toolkey_validate_server_id() {
    toolkey_require_match "server ID" "$1" '^[a-z0-9][a-z0-9._-]{0,62}$'
}

toolkey_validate_label() {
    toolkey_require_match "USB label" "$1" '^[A-Za-z0-9._-]{1,32}$'
}

toolkey_validate_principal() {
    toolkey_require_match "signing principal" "$1" '^[A-Za-z0-9._@+-]{1,128}$'
}

toolkey_validate_iface() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || toolkey_die "Invalid interface name: $1"
}

toolkey_validate_device_env_value() {
    local key=$1
    local value=$2

    case "$key" in
        SERVER_ID|TARGET_SERVER_ID)
            toolkey_validate_server_id "$value"
            ;;
        USB_VENDOR_ID|USB_MODEL_ID)
            toolkey_require_match "$key" "$value" '^[0-9A-Fa-f]{4}$'
            ;;
        USB_SERIAL_SHORT)
            toolkey_require_match "$key" "$value" '^[A-Za-z0-9._:-]{1,128}$'
            ;;
        USB_FS_UUID)
            toolkey_require_match "$key" "$value" '^[A-Fa-f0-9-]{8,64}$'
            ;;
        USB_LABEL)
            toolkey_validate_label "$value"
            ;;
        JOB_SIGNING_PRINCIPAL)
            toolkey_validate_principal "$value"
            ;;
        DEFAULT_INTERFACE)
            toolkey_validate_iface "$value"
            ;;
        *)
            toolkey_die "Unsupported device env key: $key"
            ;;
    esac
}

toolkey_validate_manifest_value() {
    local key=$1
    local value=$2

    case "$key" in
        JOB_ID)
            toolkey_require_match "$key" "$value" '^job-[0-9]{8}-[0-9]{6}-[0-9]+$'
            ;;
        DESCRIPTION)
            [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || toolkey_die "Invalid DESCRIPTION"
            ;;
        ENTRYPOINT)
            toolkey_require_match "$key" "$value" '^[A-Za-z0-9._-]{1,128}$'
            ;;
        INTERPRETER)
            case "$value" in
                /bin/bash|/bin/sh|/usr/bin/python3)
                    ;;
                *)
                    toolkey_die "Invalid INTERPRETER: $value"
                    ;;
            esac
            ;;
        TIMEOUT_SEC)
            toolkey_require_match "$key" "$value" '^[0-9]{1,6}$'
            ;;
        JOB_SHA256)
            toolkey_require_match "$key" "$value" '^[A-Fa-f0-9]{64}$'
            ;;
        TARGET_SERVER_ID)
            [[ -z "$value" ]] || toolkey_validate_server_id "$value"
            ;;
        *)
            toolkey_die "Unsupported manifest key: $key"
            ;;
    esac
}

toolkey_write_env_line() {
    local key=$1
    local value=$2

    toolkey_require_match "env key" "$key" '^[A-Z][A-Z0-9_]*$'
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || toolkey_die "Refusing multiline env value for $key"
    printf '%s=%s\n' "$key" "$value"
}

toolkey_queue_signed_job() {
    local jobs_root=$1
    local script_file=$2
    local description=$3
    local timeout_sec=$4
    local key_path=$5
    local target_server_id=${6:-}
    local job_id=${7:-job-$(date +%Y%m%d-%H%M%S)-$$$RANDOM}

    [[ -d "$jobs_root" ]] || toolkey_die "Jobs root not found: $jobs_root"
    [[ -f "$script_file" ]] || toolkey_die "Script file not found: $script_file"
    [[ -f "$key_path" ]] || toolkey_die "Signing key not found: $key_path"

    toolkey_validate_manifest_value DESCRIPTION "$description"
    toolkey_validate_manifest_value TIMEOUT_SEC "$timeout_sec"
    if [[ -n "$target_server_id" ]]; then
        toolkey_validate_server_id "$target_server_id"
    fi
    toolkey_validate_manifest_value JOB_ID "$job_id"

    local job_dir="$jobs_root/$job_id"
    [[ ! -e "$job_dir" ]] || toolkey_die "Job already exists: $job_dir"

    install -d -m 0755 "$job_dir"
    install -m 0644 "$script_file" "$job_dir/job.sh"

    local job_sha256
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

    printf '%s\n' "$job_dir"
}

toolkey_bootstrap_self_test_description() {
    local server_id=$1

    toolkey_validate_server_id "$server_id"
    printf 'bootstrap self-test for %s\n' "$server_id"
}

toolkey_remove_pending_bootstrap_self_test_jobs() {
    local jobs_root=$1
    local server_id=$2
    local description job_dir manifest_file DESCRIPTION TARGET_SERVER_ID

    [[ -d "$jobs_root" ]] || toolkey_die "Jobs root not found: $jobs_root"
    description=$(toolkey_bootstrap_self_test_description "$server_id")

    shopt -s nullglob
    for job_dir in "$jobs_root"/*; do
        [[ -d "$job_dir" ]] || continue
        manifest_file="$job_dir/manifest.env"
        [[ -f "$manifest_file" ]] || continue

        if ! toolkey_validate_env_file "$manifest_file" toolkey_validate_manifest_value >/dev/null 2>&1; then
            continue
        fi

        DESCRIPTION=
        TARGET_SERVER_ID=
        toolkey_load_env_file "$manifest_file" toolkey_validate_manifest_value
        if [[ "$DESCRIPTION" == "$description" && "$TARGET_SERVER_ID" == "$server_id" ]]; then
            rm -rf -- "$job_dir"
        fi
    done
    shopt -u nullglob
}

toolkey_queue_bootstrap_self_test_job() {
    local jobs_root=$1
    local script_file=$2
    local key_path=$3
    local server_id=$4
    local timeout_sec=${5:-180}
    local description

    description=$(toolkey_bootstrap_self_test_description "$server_id")
    toolkey_remove_pending_bootstrap_self_test_jobs "$jobs_root" "$server_id"
    toolkey_queue_signed_job "$jobs_root" "$script_file" "$description" "$timeout_sec" "$key_path" "$server_id"
}

toolkey_load_env_file() {
    local file=$1
    local validator=$2
    local line key value

    [[ -f "$file" ]] || toolkey_die "Missing env file: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || toolkey_die "Invalid env line in $file: $line"
        key=${line%%=*}
        value=${line#*=}
        toolkey_require_match "env key" "$key" '^[A-Z][A-Z0-9_]*$'
        "$validator" "$key" "$value"
        printf -v "$key" '%s' "$value"
    done < "$file"
}

toolkey_validate_env_file() {
    local file=$1
    local validator=$2

    (
        toolkey_load_env_file "$file" "$validator"
    )
}
