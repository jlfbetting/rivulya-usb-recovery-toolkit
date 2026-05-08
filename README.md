# Rivulya USB Recovery Toolkit

Rivulya is an experimental toolkit for agent-assisted offline troubleshooting
and server recovery over a signed USB handoff. It is for the cases where SSH,
VPN, Tailscale, serial, IPMI, or other live access paths are unavailable or not
enough, but you can still move one dedicated USB stick between an operator
machine and a bootstrapped Ubuntu server.

The repository includes both the USB recovery scripts and an agent skill so
tools such as Codex, Claude Code, and GitHub Copilot can guide the workflow.
The intended pattern is: prefer a better live access path first, and only use
the USB flow when offline handoff is the practical recovery path.

This is still an experimental first public release. Also it is heavily vibe-coded. Read the safety model and
limitations before using it on systems you depend on.

## Why This Toolkit

Rivulya is designed for one narrow problem: an operator needs a reliable,
explicit, auditable way to move signed troubleshooting or recovery jobs to an
Ubuntu server that currently cannot be managed normally over the network.

The workflow is as follows:

- create one dedicated recovery stick
- enroll a server once from local console
- queue signed jobs on the operator machine
- carry the stick to the server for offline execution
- carry result bundles back for review
- let an installed agent skill guide the same loop consistently

Typical uses:

- investigate network loss when SSH is unavailable
- collect system state before deciding on a repair
- run small signed recovery jobs on a server with no live remote path
- let an agent walk an operator through the USB handoff workflow

## Agent-Guided Workflow

Rivulya ships with a portable skill at `skills/rivulya-usb-offline-recovery`.
Its purpose is to help agents guide the offline recovery workflow, not to hide
it.

The skill teaches agents to:

- prefer SSH, serial console, IPMI, cloud console, VPN, Tailscale, or another live path first
- switch to the USB workflow only when offline handoff is the right tool
- guide the explicit queue, move, wait, and read-results loop
- keep recovery work focused on small signed jobs and returned evidence

Installation details for Codex, Claude Code, GitHub Copilot, generic
`SKILL.md` agents, and Skillfish-based skill installation are in
[INSTALL-AGENTS.md](INSTALL-AGENTS.md).

## How It Works

1. Run `create-stick.sh` on the operator machine to initialize one dedicated USB stick.
2. Create a server profile and bootstrap the target Ubuntu server once from local console.
3. The stick automatically carries a one-time bootstrap self-test job for that profile.
4. After bootstrap passes, queue signed jobs with `queue-job.sh`.
5. Move the stick to the server, let the job run, move the stick back, and inspect results with `read-results.sh`.

Operator-facing scripts:

- `create-stick.sh`: destructive stick initializer
- `add-server-profile.sh`: add more server profiles later
- `queue-job.sh`: sign and queue a job from the operator machine
- `read-results.sh`: mount the stick and summarize the latest result bundle
- `verify-toolkit.sh`: verify the local toolkit without USB hardware

Supporting implementation lives under `host/` and bundled jobs live under
`jobs/`.

## Requirements

Operator machine:

- Linux with Bash
- root privileges for stick initialization, mounting, and reading root-owned result files
- common tools used by the scripts: `awk`, `blkid`, `findmnt`, `grep`, `install`, `lsblk`, `mkfs.ext4`, `mount`, `partprobe`, `sfdisk`, `ssh-keygen`, `sync`, `udevadm`, `umount`, and `wipefs`
- a dedicated USB mass-storage device that can be erased

Target server:

- Ubuntu with systemd and udev
- one-time local console, serial console, or equivalent access for bootstrap
- root privileges during bootstrap
- a USB port for the dedicated stick
- runner and sample job tools including `ssh-keygen`, `timeout`, `sha256sum`, `journalctl`, `ip`, `nmcli`, `lsmod`, `lspci`, and `ethtool`

## Quick Start

From the toolkit root on the operator machine:

```bash
bash ./verify-toolkit.sh
sudo bash ./create-stick.sh
```

That initializes the stick, copies the server-side runner, creates or reuses an
Ed25519 signing key, and optionally creates one or more server profiles. Each
new profile also queues a one-time signed bootstrap self-test job.

On the target server, mount the stick and run the generated top-level bootstrap
entrypoint:

```bash
sudo mkdir -p /mnt/rivulya-toolkey
sudo mount UUID=<filesystem-uuid-from-profile> /mnt/rivulya-toolkey
sudo bash /mnt/rivulya-toolkey/BOOTSTRAP-ON-SERVER.sh [server-id]
sudo umount /mnt/rivulya-toolkey
```

Reinsert the stick into that server once so the queued bootstrap self-test runs,
then move it back to the operator machine and confirm the concise success
signal:

```bash
bash ./read-results.sh
```

In the `--- bootstrap summary` section, `bootstrap_self_test=PASS` together
with `checks_with_issues=0` means the bootstrap path is working.

Queue a first diagnostic job:

```bash
bash ./queue-job.sh ./jobs/capture-network-state.sh "capture network state" 600
```

Or target one specific enrolled server explicitly:

```bash
bash ./queue-job.sh ./jobs/capture-network-state.sh "capture network state" 600 edge-node-01
```

Do not assume fixed device names such as `/dev/sdc1`. The scripts discover the
toolkey partition by label, and the server-side unit receives the actual kernel
device from udev.

## Bootstrap Once

Bootstrap must happen before the server loses the last access path you can use.
If a server was never enrolled and is already unreachable, this toolkit cannot
install itself remotely.

Mounting the stick on the server requires `sudo`. That is expected: a script on
the USB filesystem cannot run until the filesystem is mounted somewhere first.

For each server profile, the stick contains:

```text
rivulya-toolkey/profiles/<server-id>/SERVER-SETUP.txt
rivulya-toolkey/profiles/<server-id>/install-on-server.sh
BOOTSTRAP-ON-SERVER.sh
```

`SERVER-SETUP.txt` is the human-readable reference copy. The main entrypoint is
`BOOTSTRAP-ON-SERVER.sh` from the root of the mounted stick.

If the stick has exactly one profile, the server ID argument is optional. If it
has multiple profiles, pass the chosen server ID.

The installer copies the runner, signal helper, allowed signers file, device
identity file, systemd unit, and udev rule onto the server. After that,
inserting the enrolled stick triggers `rivulya-toolkey@.service`
automatically.

## Queue, Move, Read

After bootstrap is confirmed, the recovery loop is explicit:

1. Insert the stick into the operator machine.
2. Queue one focused signed job with `queue-job.sh`.
3. Cleanly remove the stick.
4. Insert it into the bootstrapped server.
5. Wait for the job timeout and result write. For the bundled network job, 60 to 90 seconds is usually enough.
6. Move the stick back to the operator machine.
7. Run `read-results.sh` and decide whether to queue another diagnostic or a repair.

Processed jobs move to `rivulya-toolkey/archive`, and result bundles are written
under `rivulya-toolkey/results`.

That same archive behavior is what makes the automatically queued bootstrap
self-test a one-time check: once the first successful insertion processes it,
it will not run again unless you recreate or overwrite the server profile.

## Targeting And Profiles

The fourth `queue-job.sh` argument is optional.

- Omit it for a server-agnostic job that any enrolled server receiving the stick may run.
- Include a server ID when the stick is enrolled on multiple servers or when only one specific server should execute the job.

If a targeted job reaches the wrong server, the runner skips it and records
`status=target_mismatch` in the stick state.

You choose the server ID yourself when creating the profile. It is just a stable
label used by the operator and signed job manifests to identify the intended
server. Use something easy to recognize, such as `edge-node-01`, `nas-01`, or
`lab-router-02`.

The requested primary interface is only a hint. The bundled network job uses it
as a preferred NIC, and the signal helper may use it for `ethtool -p`. A wrong
value does not break enrollment, trust, or the signed job flow.

## Bundled Jobs

- `jobs/bootstrap-self-test.sh`: automatically queued for each new or updated server profile; proves the bootstrap path, runner installation, and write-back path are working
- `jobs/capture-network-state.sh`: first diagnostic for network loss; captures interface, route, NetworkManager, journal, module, driver, and `ethtool` data where available
- `jobs/capture-system-baseline.sh`: read-only wider system snapshot for cases that may not be limited to networking

## Safety Model

Rivulya is intentionally narrow:

- the operator machine is trusted to hold the signing key and queue jobs
- the server trusts one enrolled USB stick identity: USB vendor ID, model ID, serial short, and filesystem UUID
- job manifests are signed with OpenSSH Ed25519 signing
- the runner verifies the manifest signature and the signed job script hash before execution
- the runner allows only `/bin/bash`, `/bin/sh`, and `/usr/bin/python3`
- the server mounts the stick with `nosuid,nodev,noexec` and executes a staged verified copy from a private runtime directory

This does not make arbitrary USB media safe. A compromised operator machine,
stolen signing key, malicious already-enrolled stick, vulnerable queued job, or
attacker with root on the server can bypass the intended trust model. Treat the
stick and signing key as recovery credentials.

## Troubleshooting

No USB disk is listed during initialization:

- confirm the device is a USB mass-storage disk
- reinsert it and rerun `sudo bash ./create-stick.sh`
- check `lsblk -o PATH,TRAN,SIZE,MODEL,SERIAL,LABEL`

`queue-job.sh` or `read-results.sh` cannot find the toolkey partition:

- confirm the stick is inserted into the operator machine
- confirm the label is `RIVULYA_TOOLKEY`, or set `TOOLKEY_LABEL` to the label used during initialization
- inspect attached devices with `lsblk -o PATH,LABEL,UUID,TRAN`

The server does not run jobs after insertion:

- confirm the one-time bootstrap was completed for that exact server profile
- confirm the stick identity has not changed and the filesystem was not reformatted after bootstrap
- inspect on the server console:

```bash
systemctl status 'rivulya-toolkey@*'
journalctl -u 'rivulya-toolkey@*' --no-pager
udevadm info --query=property --name=/dev/<actual-partition>
```

Signature verification fails:

- confirm jobs are queued from the operator machine that owns the signing key
- confirm the stick's `common/allowed_signers` file was copied during bootstrap
- do not edit `manifest.env` after queueing a job

Results show a target mismatch:

- requeue the job with the intended server ID
- if using one stick for multiple servers, avoid untargeted jobs unless any enrolled server may safely run them

## Uninstall And Retirement

On a bootstrapped server, mount the recovery stick and run:

```bash
sudo bash /mnt/rivulya-toolkey/rivulya-toolkey/host/uninstall-server-profile.sh
```

If the stick is not mounted, the same cleanup is:

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
want to keep.

## Readiness Checklist

Before relying on Rivulya for a real outage:

- run `bash ./verify-toolkit.sh`
- initialize a spare stick and create a server profile
- bootstrap a test Ubuntu server from local console
- confirm the bootstrap self-test shows `bootstrap_self_test=PASS` and `checks_with_issues=0`
- queue and read back `jobs/capture-network-state.sh`
- queue and read back `jobs/capture-system-baseline.sh`
- if one stick serves multiple servers, confirm a targeted job is skipped by the wrong server

## Known Limitations

- bootstrap still requires one-time local or equivalent access before the outage
- the project currently focuses on Ubuntu plus systemd and udev
- job execution is root-level on the server, so only queue scripts you trust
- there is no graphical interface
- there is no remote attestation or tamper-proof audit log
- the included jobs are for diagnosis and verification, not automatic repair policy
- hardware and firmware behavior varies, so test your exact server and USB stick