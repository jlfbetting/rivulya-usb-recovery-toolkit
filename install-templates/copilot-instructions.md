Use the Rivulya USB offline recovery skill only for an Ubuntu server that lost network access and can still receive a dedicated USB stick.

Prefer SSH, serial console, remote management, VPN, Tailscale, or another live access path whenever available and sufficient.

Toolkit root: `__TOOLKIT_DIR__`

Behavior requirements:
- Confirm the server was already bootstrapped with Rivulya.
- Confirm the dedicated Rivulya USB stick exists.
- Confirm the user can physically move the stick between the operator machine and the server.
- Ask whether the stick is inserted into the operator machine before detection.
- After insertion is confirmed, detect it with the toolkit scripts or standard Linux device discovery.
- Do not assume fixed device names.
- For each USB handoff, explicitly tell the user when to move the stick, how long to wait, and when to bring it back.
- Before reading results, require explicit confirmation that the stick is back in the operator machine.
- If another cycle is needed, repeat the explicit move-and-confirm process.
