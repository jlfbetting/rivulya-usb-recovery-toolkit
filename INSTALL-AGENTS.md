# Rivulya Agent Installation Guide

Install the Rivulya USB offline recovery skill when you want an agent to guide
the signed USB recovery workflow. The skill is advisory. The toolkit scripts
still live in this repository and must be available on the operator machine.

The skill teaches agents to prefer SSH, serial console, IPMI/iDRAC/iLO, cloud
console, VPN, Tailscale, or another live access path when one is available. Use
the USB workflow only when offline handoff is the practical path.

## Skill Location

The portable skill lives at:

```text
skills/rivulya-usb-offline-recovery/SKILL.md
```

The concise always-on instruction templates live at:

```text
install-templates/AGENTS.md
install-templates/CLAUDE.md
install-templates/copilot-instructions.md
```

Each template uses one replacement token: `__TOOLKIT_DIR__`. Replace it with the
real toolkit root path after copying the template.

## Recommended Layouts

Keep the toolkit either inside the repository that needs it:

```text
tools/rivulya-usb-recovery-toolkit/
```

or in a shared tools directory on the operator machine:

```text
/path/to/rivulya-usb-recovery-toolkit/
```

In both cases, install the skill into the agent's expected skill directory and
install one always-on instruction file that points to the toolkit root.

## Codex

Workspace install:

1. Copy or symlink the skill folder to:
   `.agents/skills/rivulya-usb-offline-recovery/`
2. Copy `install-templates/AGENTS.md` to `AGENTS.md`.
3. Replace `__TOOLKIT_DIR__` in `AGENTS.md` with the toolkit root path.

Example:

```bash
mkdir -p .agents/skills
cp -R /path/to/rivulya-usb-recovery-toolkit/skills/rivulya-usb-offline-recovery .agents/skills/
cp /path/to/rivulya-usb-recovery-toolkit/install-templates/AGENTS.md ./AGENTS.md
```

## Claude Code

Workspace install:

1. Copy or symlink the skill folder to:
   `.claude/skills/rivulya-usb-offline-recovery/`
2. Copy `install-templates/CLAUDE.md` to `CLAUDE.md`.
3. Replace `__TOOLKIT_DIR__` in `CLAUDE.md` with the toolkit root path.

Example:

```bash
mkdir -p .claude/skills
cp -R /path/to/rivulya-usb-recovery-toolkit/skills/rivulya-usb-offline-recovery .claude/skills/
cp /path/to/rivulya-usb-recovery-toolkit/install-templates/CLAUDE.md ./CLAUDE.md
```

## GitHub Copilot

Workspace install:

1. Copy or symlink the skill folder to:
   `.github/skills/rivulya-usb-offline-recovery/`
2. Copy `install-templates/copilot-instructions.md` to one of:
   `.github/copilot-instructions.md`
   `.github/instructions/rivulya-usb.instructions.md`
3. Replace `__TOOLKIT_DIR__` in the copied instructions file with the toolkit
   root path.

Example:

```bash
mkdir -p .github/skills
cp -R /path/to/rivulya-usb-recovery-toolkit/skills/rivulya-usb-offline-recovery .github/skills/
cp /path/to/rivulya-usb-recovery-toolkit/install-templates/copilot-instructions.md .github/copilot-instructions.md
```

## Skillfish

If the repository has been pushed to a reachable Git host, Skillfish can install
the skill directly from the repository. Use the form that matches how the repo
is published:

```bash
npx skillfish add <owner/repo> --path skills/rivulya-usb-offline-recovery
npx skillfish add <owner/repo>/skills/rivulya-usb-offline-recovery
npx skillfish add <owner/repo>
```

After installing with Skillfish, still add the appropriate always-on instruction
file for the agent you use and replace `__TOOLKIT_DIR__` with the local toolkit
path.

## Generic SKILL.md Agents

For agents that read a `SKILL.md` folder but do not have a named convention:

1. Copy `skills/rivulya-usb-offline-recovery/` into the agent's skill search
   path.
2. Add one always-on instruction file in the project or workspace.
3. Use the closest template from `install-templates/`.
4. Replace `__TOOLKIT_DIR__` with the toolkit root path.

The always-on instruction file should tell the agent to:

- prefer SSH, serial, remote management, or another live access path first
- confirm the server was already bootstrapped
- confirm the dedicated USB stick exists
- confirm each physical USB handoff explicitly
- detect the stick after insertion instead of assuming a fixed device name
- queue focused jobs, wait for execution, then read returned results

## Verification Checklist

Codex:

- `.agents/skills/rivulya-usb-offline-recovery/SKILL.md`
- `AGENTS.md`

Claude Code:

- `.claude/skills/rivulya-usb-offline-recovery/SKILL.md`
- `CLAUDE.md`

GitHub Copilot:

- `.github/skills/rivulya-usb-offline-recovery/SKILL.md`
- `.github/copilot-instructions.md` or `.github/instructions/*.instructions.md`

Skillfish or generic agents:

- The agent can list or activate `rivulya-usb-offline-recovery`.
- The agent has always-on instructions containing the resolved toolkit path.

## Updating Later

When the toolkit changes, re-copy the skill folder and the matching template.
Keep the installed instruction file's toolkit path in sync with where the
scripts actually live.
