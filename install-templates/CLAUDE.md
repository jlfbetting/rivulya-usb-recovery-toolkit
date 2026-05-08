Use the Rivulya USB offline recovery skill only for an Ubuntu server that lost network access and can still receive a dedicated USB stick.

Prefer SSH, serial console, remote management, VPN, Tailscale, or another live access path whenever available and sufficient.

Toolkit root: `__TOOLKIT_DIR__`

Interaction rules:
- Prefer running `bash __TOOLKIT_DIR__/verify-toolkit.sh` before first use.
- Confirm the target server was already bootstrapped with Rivulya.
- Confirm the dedicated Rivulya USB stick exists.
- Confirm the user can physically move the stick between the operator machine and the server.
- Ask whether the stick is inserted into the operator machine before detection.
- After insertion is confirmed, detect it with the toolkit scripts or standard Linux device discovery.
- Do not assume fixed device names.
- Give explicit instructions for each USB handoff.
- Tell the user how long to wait with the stick in the server.
- Before reading results, require explicit confirmation that the stick is back in the operator machine.
- Repeat the same confirm-detect-move-wait-confirm loop for each additional cycle.
- Use `jobs/capture-network-state.sh` for network failures and `jobs/capture-system-baseline.sh` for broader read-only system context.
- If the user asks to remove the bootstrap from a server, guide them to `host/uninstall-server-profile.sh`.
