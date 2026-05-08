#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

echo "Removing Rivulya USB recovery bootstrap files..."

systemctl stop 'rivulya-toolkey@*.service' >/dev/null 2>&1 || true

rm -f /etc/udev/rules.d/99-rivulya-toolkey.rules
rm -f /etc/systemd/system/rivulya-toolkey@.service
rm -rf /etc/rivulya-toolkey
rm -rf /usr/local/lib/rivulya-toolkey

systemctl daemon-reload
udevadm control --reload

echo "Rivulya USB recovery bootstrap removed."
echo "This does not erase any USB stick, operator signing key, or result bundles."
