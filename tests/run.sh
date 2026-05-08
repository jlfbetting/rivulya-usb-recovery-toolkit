#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_parent="$repo_root/.test-output"
mkdir -p "$tmp_parent"
tmp_dir=$(mktemp -d "$tmp_parent/run.XXXXXX")
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

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

jobs_root="$tmp_dir/jobs"
install -d -m 0755 "$jobs_root"
signing_key="$tmp_dir/test-signing-key"
ssh-keygen -q -t ed25519 -N '' -C rivulya-toolkey -f "$signing_key" >/dev/null
queued_job_dir=$(toolkey_queue_signed_job "$jobs_root" "$hash_job" "bootstrap self-test" 90 "$signing_key" edge-node-01 job-20260508-120001-5678)
assert_eq "$jobs_root/job-20260508-120001-5678" "$queued_job_dir" "queued job dir"
toolkey_load_env_file "$queued_job_dir/manifest.env" toolkey_validate_manifest_value
assert_eq "edge-node-01" "$TARGET_SERVER_ID" "queued job target server id"
assert_eq "90" "$TIMEOUT_SEC" "queued job timeout"
assert_eq "bootstrap self-test" "$DESCRIPTION" "queued job description"
[[ -f "$queued_job_dir/manifest.sig" ]] || {
    echo "FAIL missing manifest signature" >&2
    exit 1
}
expect_fail toolkey_queue_signed_job "$jobs_root" "$hash_job" "bootstrap self-test" 90 "$signing_key" '../bad' job-20260508-120002-9012

bootstrap_script="$repo_root/jobs/bootstrap-self-test.sh"
bootstrap_description=$(toolkey_bootstrap_self_test_description edge-node-01)
assert_eq "bootstrap self-test for edge-node-01" "$bootstrap_description" "bootstrap self-test description"
bootstrap_job_dir=$(toolkey_queue_bootstrap_self_test_job "$jobs_root" "$bootstrap_script" "$signing_key" edge-node-01 180)
toolkey_load_env_file "$bootstrap_job_dir/manifest.env" toolkey_validate_manifest_value
assert_eq "bootstrap self-test for edge-node-01" "$DESCRIPTION" "bootstrap helper description"
assert_eq "180" "$TIMEOUT_SEC" "bootstrap helper timeout"
pending_before=$(find "$jobs_root" -mindepth 1 -maxdepth 1 -type d | wc -l | awk '{ print $1 }')
assert_eq "2" "$pending_before" "pending jobs before bootstrap refresh"
bootstrap_job_dir=$(toolkey_queue_bootstrap_self_test_job "$jobs_root" "$bootstrap_script" "$signing_key" edge-node-01 180)
pending_after=$(find "$jobs_root" -mindepth 1 -maxdepth 1 -type d | wc -l | awk '{ print $1 }')
assert_eq "2" "$pending_after" "pending jobs after bootstrap refresh"
toolkey_load_env_file "$bootstrap_job_dir/manifest.env" toolkey_validate_manifest_value
assert_eq "bootstrap self-test for edge-node-01" "$DESCRIPTION" "bootstrap helper refreshed description"

SKIP_SELF_TESTS=1 bash "$repo_root/verify-toolkit.sh" > "$tmp_dir/verify-toolkit.txt"

echo "All tests passed"
