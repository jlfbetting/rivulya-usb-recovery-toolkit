---
name: rivulya-usb-offline-recovery
description: Use the Rivulya USB recovery toolkit to create a dedicated recovery stick, bootstrap Ubuntu servers, and run signed offline USB jobs when network access is unavailable.
---

# Rivulya USB Offline Recovery

## Purpose

Use this skill when an Ubuntu server needs an offline recovery path through a dedicated USB stick. The toolkit can:

- create a dedicated recovery stick on an operator machine
- generate per-server bootstrap instructions
- enroll an Ubuntu server once from local console
- queue signed diagnostic or repair jobs later when SSH or network access is unavailable
- read returned result bundles from the stick

Do not use this workflow when SSH, serial console, IPMI/iDRAC/iLO, cloud console, VPN, Tailscale, or another live access path is available and sufficient.

## Preconditions

Before choosing the USB workflow, confirm:

- whether a better live access path is available right now
- whether the user has a dedicated USB stick that can be erased or already initialized
- whether the user can physically move the stick between the operator machine and server
- whether the target server is already bootstrapped, or whether the user still has local console access for one-time bootstrap
- which server profile ID should receive jobs

If the target server was never bootstrapped and is already unreachable without local console access, this workflow cannot install itself remotely. Explain that one-time local bootstrap is required first.

## Toolkit Location

The toolkit must be available on the operator machine. If `TOOLKIT_DIR` is not already known, ask for it once and reuse that path.

Assume commands are run from the toolkit root or with `TOOLKIT_DIR` set.

## Setup Commands

Create a new dedicated stick:

```bash
sudo bash "${TOOLKIT_DIR:-.}/create-stick.sh"
```

Add another server profile to an existing stick:

```bash
sudo bash "${TOOLKIT_DIR:-.}/add-server-profile.sh"
```

During bootstrap, tell the user to follow the generated `SERVER-SETUP.txt` for the specific server profile. It includes the exact filesystem UUID and profile path to mount and install.

## Recovery Loop

For each offline recovery cycle:

1. Confirm the stick is inserted into the operator machine.
2. Detect it with toolkit scripts or `lsblk`/`blkid`; never assume a device name like `sdc1`.
3. Create or choose one focused job script.
4. Queue it, normally with a target server ID:

   ```bash
   bash "${TOOLKIT_DIR:-.}/queue-job.sh" /path/to/job.sh "description" 600 server-id
   ```

5. Tell the user operator-side work is complete and the stick can be cleanly removed.
6. Ask the user to insert the stick into the server.
7. Tell the user how long to wait. Use 60-90 seconds for the bundled diagnostic job unless a longer timeout was queued.
8. Ask the user to move the stick back to the operator machine.
9. Wait for explicit confirmation that the stick is back before reading results:

   ```bash
   bash "${TOOLKIT_DIR:-.}/read-results.sh"
   ```

10. Use the result bundle to decide whether to queue another diagnostic, queue a fix, or ask for one manual console step.

Repeat the same explicit confirm-detect-move-wait-confirm loop for every cycle.

## Default Diagnostic

Use `jobs/capture-network-state.sh` as the first diagnostic when the failure is network or Ethernet related. It captures interface, route, NetworkManager, kernel, module, journal, driver, and `ethtool` data where available.

Example:

```bash
bash "${TOOLKIT_DIR:-.}/queue-job.sh" "${TOOLKIT_DIR:-.}/jobs/capture-network-state.sh" "capture network state" 600 server-id
```

## Guidance

- Prefer small, idempotent jobs over broad scripts.
- Avoid destructive repair steps until returned diagnostics identify the failure path.
- If the stick has multiple server profiles, always queue jobs with the target server ID.
- If result files are root-owned, use `read-results.sh`; it already handles privileged reads.
- Keep USB handoff instructions explicit. Do not silently probe for results before the user confirms the stick is back.
- Treat the stick and signing key as recovery credentials.

## Runner Guarantees

The server-side runner is designed to:

- trigger only for the enrolled USB stick identity
- verify signed job manifests with OpenSSH signing
- validate the signed job script hash before execution
- execute the staged verified job copy from a private runtime directory
- allow only `/bin/bash`, `/bin/sh`, and `/usr/bin/python3` interpreters
- write result bundles under `rivulya-toolkey/results`
