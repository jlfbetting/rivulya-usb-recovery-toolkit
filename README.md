# Rivulya USB Recovery Toolkit

Rivulya USB Recovery Toolkit is an experimental Bash and systemd toolkit for
offline server recovery over USB. It helps an operator recover a server without
network access by moving one dedicated USB stick between an operator machine and
Ubuntu servers that have been enrolled through the included one-time bootstrap
workflow.

The first public release is usable for careful operators, but it is not a
production support product. Read the trust boundaries and limitations before
using it on systems you depend on.

## Status

- Experimental first public release.
- Ubuntu-focused. Other Linux distributions may work with changes, but are not
  the primary target.
- MIT licensed.
- Intended for cases where SSH, VPN, Tailscale, normal remote management, or a
  serial console is unavailable or insufficient.
- Includes an agent skill for Codex, Claude Code, and GitHub Copilot, plus
  installation notes for Skillfish and generic `SKILL.md` agents.

## What It Does

Rivulya creates a dedicated USB recovery stick and server profile, installs a
small server-side systemd/udev runner during a one-time local bootstrap, then
uses the stick as a USB stick job transport for signed recovery scripts.

Typical use cases:

- debug an Ubuntu server that lost Ethernet connectivity
- run diagnostics when SSH is unavailable
- collect NetworkManager, kernel, driver, route, and interface state
- queue small repair or inspection scripts for an offline server
- carry result bundles back to the operator machine without network access

The toolkit contains:

- `create-stick.sh`: destructive initializer for a dedicated USB stick.
- `add-server-profile.sh`: adds more server profiles to an initialized stick.
- `queue-job.sh`: signs and queues a job from the operator machine.
- `read-results.sh`: mounts the stick and prints the latest result bundle.
- `verify-toolkit.sh`: checks the local toolkit without USB hardware.
- `host/`: server-side installer, runner, signal helper, and systemd unit.
- `jobs/bootstrap-self-test.sh`: one-time proof job queued automatically for each new server profile.
- `jobs/capture-network-state.sh`: sample diagnostic job for network failures.
- `jobs/capture-system-baseline.sh`: sample read-only baseline diagnostic job.
- `skills/rivulya-usb-offline-recovery/SKILL.md`: agent skill instructions.

## Threat Model And Trust Boundaries

Rivulya is designed for a narrow offline recovery workflow:

- The operator machine is trusted to hold the signing key and queue jobs.
- The server trusts one enrolled USB stick identity: USB vendor ID, model ID,
  serial short, and filesystem UUID.
- Job manifests are signed with an OpenSSH Ed25519 signing key.
- The server verifies manifests with `ssh-keygen -Y verify` and validates the
  job script hash before execution.
- The server-side runner only allows `/bin/bash`, `/bin/sh`, and
  `/usr/bin/python3` as interpreters.
- The server mounts the stick with `nosuid,nodev,noexec` and copies verified
  job content into a private staging directory before execution.

This does not make arbitrary USB media safe. A compromised operator machine,
stolen signing key, malicious already-enrolled stick, vulnerable job script, or
attacker with root on the server can bypass the intended trust model. Treat the
stick and signing key as recovery credentials.

## Requirements

Operator machine:

- Linux with Bash.
- Root privileges for stick initialization, mounting, and reading root-owned
  result files.
- Common system tools used by the scripts: `awk`, `blkid`, `findmnt`, `grep`,
  `install`, `lsblk`, `mkfs.ext4`, `mount`, `partprobe`, `sfdisk`,
  `ssh-keygen`, `sync`, `udevadm`, `umount`, and `wipefs`.
- A dedicated USB mass-storage device that can be erased.

Target server:

- Ubuntu with systemd and udev.
- Local console, serial console, or other one-time access for bootstrap.
- Root privileges during bootstrap.
- USB port available for the dedicated stick.
- Tools used by the runner and sample job, including `ssh-keygen`, `timeout`,
  `sha256sum`, `journalctl`, `ip`, `nmcli`, `lsmod`, `lspci`, and `ethtool`.
  Some sample job outputs may be missing if optional tools are not installed.

## Quick Start

From the toolkit root on the operator machine:

```bash
bash ./verify-toolkit.sh
```

Then initialize a dedicated USB stick:

```bash
sudo bash ./create-stick.sh
```

The initializer lists attached USB disks, asks which one to erase, creates an
ext4 filesystem, creates or reuses an Ed25519 signing key, copies the server-side
runner to the stick, and optionally creates one or more server profiles. Each
new server profile also queues a one-time signed bootstrap self-test job that
the server will run on first reinsertion after bootstrap.

To add another server profile later:

```bash
sudo bash ./add-server-profile.sh
```

To queue the included diagnostic job for one server:

```bash
bash ./queue-job.sh ./jobs/capture-network-state.sh "capture network state" 600 edge-node-01
```

Move the stick to the server, wait for the job to run, move the stick back, then
read results:

```bash
bash ./read-results.sh
```

Do not assume fixed device names such as `/dev/sdc1`. The scripts discover the
toolkey partition by label, and the server-side unit receives the actual kernel
device from udev.

## One-Time Server Bootstrap

Bootstrap must happen before the server loses the access path you rely on. If a
server was never enrolled, this toolkit cannot magically install itself after
the server is already unreachable.

For each server profile, the stick contains:

```text
rivulya-toolkey/profiles/<server-id>/install-on-server.sh
rivulya-toolkey/profiles/<server-id>/SERVER-SETUP.txt
```

On the target server, use the exact commands printed in that profile's
`SERVER-SETUP.txt`. They follow this shape:

```bash
sudo mkdir -p /mnt/rivulya-toolkey
sudo mount UUID=<filesystem-uuid-from-profile> /mnt/rivulya-toolkey
sudo bash /mnt/rivulya-toolkey/rivulya-toolkey/profiles/<server-id>/install-on-server.sh
sudo umount /mnt/rivulya-toolkey
```

The installer copies the runner, signal helper, allowed signers file, device
identity file, systemd unit, and udev rule onto the server. After that, inserting
the enrolled USB stick triggers `rivulya-toolkey@.service` automatically.

Each newly created server profile also stages a targeted bootstrap self-test job
on the stick. After you run `install-on-server.sh`, reinsert the stick into that
same server once. The runner should execute the bootstrap self-test automatically
and write a result bundle back to the stick. Move the stick back to the operator
machine and run `bash ./read-results.sh` to confirm that the bootstrap self-test
completed successfully before relying on the toolkit for later recovery jobs.

## Queue And Read Result Loop

After bootstrap is confirmed, each recovery cycle is explicit:

1. Insert the dedicated stick into the operator machine.
2. Queue one focused signed job with `queue-job.sh`.
3. Cleanly remove the stick.
4. Insert it into the bootstrapped server.
5. Wait long enough for the job timeout and result write. For the sample network
   diagnostic job, 60 to 90 seconds is usually enough.
6. Move the stick back to the operator machine.
7. Run `read-results.sh` to inspect status, metadata, stdout, stderr, and files
   written by the job.

The runner archives processed jobs under `rivulya-toolkey/archive` and writes
result bundles under `rivulya-toolkey/results`. That same archive behavior is
what makes the automatically queued bootstrap self-test a one-time check: once
the first successful insertion processes it, it will not run again unless you
recreate or overwrite the server profile.

## Multi-Server Stick Usage

One stick can contain profiles for multiple servers. In that mode, always pass a
target server ID when queuing jobs:

```bash
bash ./queue-job.sh ./jobs/capture-network-state.sh "capture network state" 600 edge-node-01
```

If the target server ID does not match the server that receives the stick, the
runner skips the job and records `status=target_mismatch` in the stick state.

You choose the server ID yourself when creating the server profile. It is just a
stable label used by the operator and the signed job manifests to target the
right server profile. Pick something easy to recognize at a console.

Use server IDs that are easy to recognize at a console, such as `edge-node-01`,
`nas-01`, or `lab-router-02`.

When creating a server profile, the script also asks for a primary interface.
That value is only a hint. It is passed to the sample network diagnostic job so
it can prefer the expected NIC, and it is also used by the local signal helper
to blink link lights with `ethtool -p` when possible. A wrong value does not
break enrollment, trust, or the signed job flow. If the hint is wrong or the
interface does not exist, the sample network job falls back to auto-detecting a
physical interface.

## Included Sample Diagnostic Job

`jobs/capture-network-state.sh` is the default first job when you need to debug
network loss. It writes files into the job result directory, including:

- detected interface context
- `uname -a`
- `/sys/class/net` listing
- brief link, address, and route output
- NetworkManager device and connection state
- loaded kernel modules
- PCI network driver details
- recent kernel and NetworkManager journal lines
- relevant modprobe blacklist or driver configuration
- `ethtool` and driver path data for the detected physical interface

It is diagnostic only. It does not modify network configuration.

`jobs/bootstrap-self-test.sh` is queued automatically for each new or updated
server profile. It is a read-only proof job that records hostname, server ID,
kernel, required installed bootstrap files, and visibility of the mounted
toolkey layout. A successful result bundle shows that the server bootstrap, job
signature verification, job execution path, and write-back to the USB stick are
all functioning together.

`jobs/capture-system-baseline.sh` is a broader read-only baseline job. It
captures uptime, OS release, kernel command line, disk and mount state, block
devices, failed systemd units, selected service status, high-priority journal
lines, memory, and a process snapshot. Use it when the outage may involve more
than networking or when you want a quick system overview before deciding on a
repair job.

## Troubleshooting

No USB disk is listed during initialization:

- Confirm the device is a USB mass-storage disk.
- Reinsert it and rerun `sudo bash ./create-stick.sh`.
- Check `lsblk -o PATH,TRAN,SIZE,MODEL,SERIAL,LABEL`.

`queue-job.sh` or `read-results.sh` cannot find the toolkey partition:

- Confirm the stick is inserted into the operator machine.
- Confirm the label is `RIVULYA_TOOLKEY`, or set `TOOLKEY_LABEL` to the label
  used during initialization.
- Use `lsblk -o PATH,LABEL,UUID,TRAN` to inspect attached devices.

The server does not run jobs after insertion:

- Confirm the one-time bootstrap was completed for that exact server profile.
- Confirm the stick identity has not changed and the filesystem was not
  reformatted after bootstrap.
- On the server console, inspect:

```bash
systemctl status 'rivulya-toolkey@*'
journalctl -u 'rivulya-toolkey@*' --no-pager
udevadm info --query=property --name=/dev/<actual-partition>
```

Signature verification fails:

- Confirm jobs are queued from the operator machine that owns the signing key.
- Confirm the stick's `common/allowed_signers` file was copied during server
  bootstrap.
- Do not edit `manifest.env` after queueing a job.

Results show a target mismatch:

- Requeue the job with the intended server ID.
- If using one stick for multiple servers, do not queue untargeted jobs.

## Uninstall Notes

On a bootstrapped server, use the uninstall helper copied onto the recovery
stick:

```bash
sudo bash /mnt/rivulya-toolkey/rivulya-toolkey/host/uninstall-server-profile.sh
```

If the stick is not mounted, the helper does the same cleanup as these manual
commands:

```bash
sudo rm -f /etc/udev/rules.d/99-rivulya-toolkey.rules
sudo rm -f /etc/systemd/system/rivulya-toolkey@.service
sudo rm -rf /etc/rivulya-toolkey /usr/local/lib/rivulya-toolkey
sudo systemctl daemon-reload
sudo udevadm control --reload
```

On the operator machine, remove the signing key only if no enrolled server still
depends on it:

```bash
rm -f ~/.ssh/rivulya_toolkey_signing ~/.ssh/rivulya_toolkey_signing.pub
```

To retire a stick, erase or reformat it after copying any result bundles you
need to keep.

## Manual Validation Checklist

Before relying on the workflow for a real outage:

- Run `bash verify-toolkit.sh` from the toolkit root.
- Initialize a spare USB stick with `create-stick.sh`.
- Create a server profile with the correct server ID and primary interface.
- Bootstrap a test Ubuntu server from local console.
- Reinsert the stick once and confirm the systemd unit triggers.
- Queue `jobs/capture-network-state.sh` with the target server ID.
- Queue `jobs/capture-system-baseline.sh` with the target server ID.
- Move the stick to the server and wait at least 60 to 90 seconds.
- Move the stick back and run `read-results.sh`.
- Confirm the result bundle contains `status.env`, `meta.env`, `stdout.txt`,
  `stderr.txt`, and the network diagnostic files.
- Repeat the queue/read loop with a second small read-only job.
- For a multi-server stick, confirm a job targeted at one server is skipped by a
  different server.

## Known Limitations

- Bootstrap requires one-time local or equivalent access before the outage.
- This project currently focuses on Ubuntu and systemd/udev.
- Job execution is root-level on the server, so only queue scripts you trust.
- The USB stick is a credential. Store it accordingly.
- The signing key is a credential. Protect it and back it up deliberately.
- There is no graphical interface.
- There is no remote attestation or tamper-proof audit log.
- The included sample job is for diagnosis, not automatic repair.
- Hardware and firmware behavior varies. Test your exact server and USB stick.

## Agent Installation

The repository includes a skill at:

```text
skills/rivulya-usb-offline-recovery/SKILL.md
```

Install notes for Codex, Claude Code, GitHub Copilot, Skillfish, and generic
`SKILL.md` agents are in [INSTALL-AGENTS.md](INSTALL-AGENTS.md). The agent skill
does not replace operator judgment; it teaches agents to prefer SSH, serial, or
remote management when available, then guide the explicit USB handoff workflow
when offline recovery is the right option.