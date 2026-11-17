# Using these skills in Claude Code

Claude Code discovers skills on disk. One skill = one directory containing a `SKILL.md`.
Nothing needs to be compiled or registered.

## Install

Personal — available in every project you open:

```bash
mkdir -p ~/.claude/skills
cp -r skills/darra-ethercat        ~/.claude/skills/
cp -r skills/darra-runtime-install ~/.claude/skills/
cp -r skills/darra-verify          ~/.claude/skills/
```

Project-scoped — checked in with the repository so every teammate gets it:

```bash
mkdir -p .claude/skills
cp -r /path/to/ethercat-skill/skills/darra-ethercat        .claude/skills/
cp -r /path/to/ethercat-skill/skills/darra-runtime-install .claude/skills/
cp -r /path/to/ethercat-skill/skills/darra-verify          .claude/skills/
```

The layout inside each directory must stay exactly `skills/<name>/SKILL.md` — Claude Code
reads the `name` and `description` from the YAML front matter.

## Use

Start a new session after copying. The skills appear in the session's skill list. Then either:

- **Let it route itself** — the `description` field lists the trigger words. "Write me a C#
  master program that scans slaves and enters OP" pulls in `darra-ethercat`.
- **Ask for one by name** — `/darra-ethercat`, `/darra-runtime-install`, `/darra-verify`, or
  "use darra-verify on this machine".

## What happens on disk

The agent only reads text. The skills never install anything by themselves:

- `darra-ethercat` produces code. It will tell the agent to read
  <https://ethercat.darra.xyz/ai-prompts.txt> before writing any API call.
- `darra-runtime-install` has the agent **ask you first**, then run the official installer
  with `--silent --install`. It will not reboot your machine on its own.
- `darra-verify` only builds a throwaway console project and scans. Read-only with respect to
  drivers, adapters, and bus configuration.

## Refreshing

This repository tracks the skills that ship with the product. Re-run the `cp -r` commands
after pulling to update them; do not edit the copies in place, or the next update will
silently drop your changes.
