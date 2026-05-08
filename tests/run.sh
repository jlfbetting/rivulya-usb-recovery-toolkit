#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir="$repo_root/.test-output"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

. "$repo_root/lib/toolkey-common.sh"

assert_eq() {
    local expected=$1
    local actual=$2
    local label=$3

    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL $label: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

expect_fail() {
    if ("$@") >/dev/null 2>&1; then
        echo "FAIL expected command to fail: $*" >&2
        exit 1
    fi
}

assert_eq "edge-node-01" "$(toolkey_sanitize_id 'Edge Node 01')" "sanitize id"
toolkey_validate_server_id "edge-node-01"
expect_fail toolkey_validate_server_id "../bad"
toolkey_validate_label "RIVULYA_TOOLKEY"
expect_fail toolkey_validate_label "bad label"

env_file="$tmp_dir/device.env"
{
    toolkey_write_env_line SERVER_ID edge-node-01
    toolkey_write_env_line USB_VENDOR_ID 1234
    toolkey_write_env_line USB_MODEL_ID abcd
    toolkey_write_env_line USB_SERIAL_SHORT SERIAL_01
    toolkey_write_env_line USB_FS_UUID 11111111-2222-3333-4444-555555555555
    toolkey_write_env_line USB_LABEL RIVULYA_TOOLKEY
    toolkey_write_env_line JOB_SIGNING_PRINCIPAL rivulya-toolkey
    toolkey_write_env_line DEFAULT_INTERFACE enp1s0
} > "$env_file"
toolkey_load_env_file "$env_file" toolkey_validate_device_env_value
assert_eq "edge-node-01" "$SERVER_ID" "loaded server id"

manifest_file="$tmp_dir/manifest.env"
{
    toolkey_write_env_line JOB_ID job-20260508-120000-1234
    toolkey_write_env_line DESCRIPTION "capture network state"
    toolkey_write_env_line ENTRYPOINT job.sh
    toolkey_write_env_line INTERPRETER /bin/bash
    toolkey_write_env_line TIMEOUT_SEC 600
    toolkey_write_env_line JOB_SHA256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    toolkey_write_env_line TARGET_SERVER_ID edge-node-01
} > "$manifest_file"
toolkey_load_env_file "$manifest_file" toolkey_validate_manifest_value
assert_eq "capture network state" "$DESCRIPTION" "loaded description"
assert_eq "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "$JOB_SHA256" "loaded job sha256"

bad_manifest="$tmp_dir/bad-manifest.env"
{
    toolkey_write_env_line JOB_ID job-20260508-120000-1234
    toolkey_write_env_line ENTRYPOINT ../bad
} > "$bad_manifest"
expect_fail toolkey_load_env_file "$bad_manifest" toolkey_validate_manifest_value
expect_fail toolkey_validate_env_file "$bad_manifest" toolkey_validate_manifest_value

fail_job="$tmp_dir/fail-job.sh"
printf '#!/usr/bin/env bash\nexit 7\n' > "$fail_job"
chmod +x "$fail_job"
set +e
RIVULYA_TOOLKEY_RUN_JOB_ONLY=1 bash "$repo_root/host/runner.sh" 30 /bin/bash "$fail_job" "$tmp_dir/stdout.txt" "$tmp_dir/stderr.txt"
exit_code=$?
set -e
assert_eq "7" "$exit_code" "runner preserves failing exit code"

hash_job="$tmp_dir/hash-job.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hash_job"
expected_hash=$(sha256sum "$hash_job" | awk '{ print $1 }')
actual_hash=$(RIVULYA_TOOLKEY_HASH_FILE_ONLY=1 bash "$repo_root/host/runner.sh" "$hash_job")
assert_eq "$expected_hash" "$actual_hash" "runner hashes staged job file"
expect_fail env RIVULYA_TOOLKEY_VERIFY_HASH_ONLY=1 bash "$repo_root/host/runner.sh" "$hash_job" 0000000000000000000000000000000000000000000000000000000000000000
RIVULYA_TOOLKEY_VERIFY_HASH_ONLY=1 bash "$repo_root/host/runner.sh" "$hash_job" "$expected_hash"

echo "All tests passed"
