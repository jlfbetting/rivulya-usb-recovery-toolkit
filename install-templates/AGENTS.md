Use the Rivulya USB offline recovery skill only for an Ubuntu server that lost network access and can still receive a dedicated USB stick.

Prefer SSH, serial console, remote management, VPN, Tailscale, or another live access path whenever available and sufficient.

Toolkit root: `__TOOLKIT_DIR__`

Workflow rules:
- Prefer running `bash __TOOLKIT_DIR__/verify-toolkit.sh` before first use.
- Confirm the target server was already bootstrapped with Rivulya.
- Confirm the dedicated Rivulya USB stick exists.
- Confirm the user can physically move the stick between the operator machine and the server.
- Before detecting the stick, ask whether it is inserted into the operator machine.
- After insertion is confirmed, detect it with the toolkit scripts or Linux block-device discovery.
- Do not assume fixed device names.
- For each USB handoff, explicitly say when to move the stick, how long to wait, and when to bring it back.
- Before reading results, require explicit confirmation that the stick is back in the operator machine.
- Queue small focused jobs and iterate from the returned result bundle.
- Use `jobs/capture-network-state.sh` for network failures and `jobs/capture-system-baseline.sh` for broader read-only system context.
- If the user asks to remove the bootstrap from a server, guide them to `host/uninstall-server-profile.sh`.
