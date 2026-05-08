#!/usr/bin/env bash
set -euo pipefail

kit_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$kit_root"

failures=0

ok() {
    printf 'ok: %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    failures=$((failures + 1))
}

require_file() {
    local path=$1
    [[ -f "$path" ]] && ok "found $path" || fail "missing $path"
}

require_command() {
    local name=$1
    command -v "$name" >/dev/null 2>&1 && ok "found command $name" || fail "missing command $name"
}

required_files=(
    create-stick.sh
    add-server-profile.sh
    queue-job.sh
    read-results.sh
    lib/toolkey-common.sh
    host/install-server-profile.sh
    host/runner.sh
    host/signal.sh
    host/uninstall-server-profile.sh
    host/rivulya-toolkey@.service
    jobs/capture-network-state.sh
    jobs/capture-system-baseline.sh
    skills/rivulya-usb-offline-recovery/SKILL.md
)

for path in "${required_files[@]}"; do
    require_file "$path"
done

required_commands=(
    awk
    bash
    blkid
    find
    grep
    install
    lsblk
    mount
    sha256sum
    ssh-keygen
    systemd-analyze
    timeout
    udevadm
    umount
)

for name in "${required_commands[@]}"; do
    require_command "$name"
done

scripts=(
    create-stick.sh
    add-server-profile.sh
    queue-job.sh
    read-results.sh
    verify-toolkit.sh
    lib/toolkey-common.sh
    host/install-server-profile.sh
    host/runner.sh
    host/signal.sh
    host/uninstall-server-profile.sh
    jobs/capture-network-state.sh
    jobs/capture-system-baseline.sh
    tests/run.sh
)

if bash -n "${scripts[@]}"; then
    ok "bash syntax"
else
    fail "bash syntax check failed"
fi

if python3 - <<'PY'
from pathlib import Path
p = Path("skills/rivulya-usb-offline-recovery/SKILL.md")
text = p.read_text()
assert text.startswith("---\n")
frontmatter = text.split("---\n", 2)[1]
assert "name: rivulya-usb-offline-recovery" in frontmatter
assert "description:" in frontmatter
PY
then
    ok "skill frontmatter"
else
    fail "skill frontmatter validation failed"
fi

tmp_dir=$(mktemp -d /tmp/rivulya-systemd-verify.XXXXXX)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

install -d "$tmp_dir/etc/systemd/system" "$tmp_dir/usr/local/lib/rivulya-toolkey"
cp host/rivulya-toolkey@.service "$tmp_dir/etc/systemd/system/"
cp host/runner.sh "$tmp_dir/usr/local/lib/rivulya-toolkey/runner.sh"
chmod 0755 "$tmp_dir/usr/local/lib/rivulya-toolkey/runner.sh"

if systemd-analyze --recursive-errors=no verify --root="$tmp_dir" rivulya-toolkey@i.service; then
    ok "systemd unit"
else
    fail "systemd unit verification failed"
fi

if [[ ${SKIP_SELF_TESTS:-0} != 1 ]]; then
    if bash tests/run.sh; then
        ok "self tests"
    else
        fail "self tests failed"
    fi
fi

if [[ $failures -eq 0 ]]; then
    echo "Rivulya toolkit verification passed."
else
    echo "Rivulya toolkit verification failed with $failures issue(s)." >&2
    exit 1
fi
