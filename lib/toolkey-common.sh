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
