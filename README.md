# Darra EtherCAT Skills

Agent skills for **Darra EtherCAT Master**: install the runtime on Windows, write master programs in six languages, verify a live bus, and confirm an install is actually alive.

These are plain Markdown instruction files. There is no build step and nothing to compile — an agent reads the relevant `SKILL.md` and follows it.

> The skill text is written in Chinese. Each file's YAML front matter carries the machine-readable English name plus the Chinese trigger words it matches on.

---

## Skills

| Skill | What it solves | Reach for it when |
|---|---|---|
| [`darra-ethercat`](skills/darra-ethercat/SKILL.md) | Writing master programs in C#, Python, Java, C, C++, or Rust: DENI configuration, build/init order, the state machine up to OP, PDO struct mapping, SDO, CiA 402 servo control, DC, cycle timing. Ships a **complete runnable C# program and a complete runnable Python program** (select NIC → build → OP → cyclic callback → SDO → Close), plus a six-language entry-point comparison table. | The task is to write or review master-side code. |
| [`darra-ethercat-windows`](skills/darra-ethercat-windows/SKILL.md) | Windows end-to-end: one installer covers runtime + driver + GUI + six SDKs; silent install/upgrade/uninstall and exit codes, post-install alive check, first master program, Windows-specific traps (exclusive NIC, driver swap needs reboot, which of the three scan entries to use), and the three-state scan verdict. | Someone is on Windows and needs the whole path from installer to first running master. |
| [`darra-runtime-install`](skills/darra-runtime-install/SKILL.md) | Downloading and silently installing the runtime: fixed download URL, SHA256 check, silent install / uninstall, exit-code interpretation (3010 = success, reboot pending), upgrade-in-place semantics, and the "never auto-reboot, never install without confirmation" boundary. | The machine needs the runtime, or an install / upgrade / uninstall question comes up. |
| [`darra-verify`](skills/darra-verify/SKILL.md) | Proving the install is actually alive, in six layers: L0 installer exit code → L1 SDK files → L2 SDK loads → L3 adapters enumerate → L4 bus scan (strict three-state) → L5 optional: reach OP and read `0x1018:01`. Emits machine-readable JSON. | Someone asks "did it install correctly?" or "why does it scan nothing?". |

## How to use

- **Claude Code as a plugin** — one command, see [Plugin install](#plugin-install) below.
- **Claude Code by copying files** — see [`examples/claude-code.md`](examples/claude-code.md).
- **Any other agent framework** — see [`examples/generic-agent.md`](examples/generic-agent.md).

Short version: put each skill directory under your agent's skills folder, or feed the matching `SKILL.md` into the system prompt when that kind of work comes up. The skill's `description` field is the routing key — it lists the trigger words.

### Plugin install

This repository declares itself a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`), so no copying is needed:

```bash
claude plugin marketplace add DarraTechnology/ethercat-skill
claude plugin install darra-ethercat-skill@darra-ethercat-skills
```

Or in-session: `/plugin marketplace add DarraTechnology/ethercat-skill`, then
`/plugin install darra-ethercat-skill@darra-ethercat-skills`. All four skills come with that one plugin.

### Package-manager install

The same skills are also installable straight from GitHub with the open `skills` CLI (works with any agent that reads a `skills/` directory):

```bash
npx skills add DarraTechnology/ethercat-skill
```

## Getting the runtime

Two stable links. Do not construct versioned URLs — the versioned installer filenames are not guessable.

- Website: <https://ethercat.darra.xyz/>
- Installer: <https://download.darra.xyz/ethercat/client/Darra-EtherCAT-Setup.exe>

The public installer is Windows x64 only. There is no public Linux build.

## Source of truth

The skills are maintained alongside the product. If a skill and this README disagree, the skill wins. If a skill and the product docs disagree, the docs win:

- AI rules file: <https://ethercat.darra.xyz/ai-prompts.txt>
- SDK documentation: <https://ethercat.darra.xyz/doc/sdk/csharp>

API names, initialization order, state-machine semantics, PDO mapping, SDO rules, CiA 402 behavior, and scan verdicts all come from that rules file. Agents are told to stop rather than invent an interface when it cannot be read.

## What these skills do not claim

`darra-verify` runs L0–L4 without any slave attached: the installer exit code was a success code, the SDK files are present, the SDK loads, the adapters enumerate, and the scan verdict is one of three states — `null` = not measured, `0` = measured empty bus, `N > 0` = measured N slaves.

L5 is optional and needs a `config.deni` plus real slaves; when it passes it adds exactly two facts — the master reached OP, and `0x1018:01` reads from a slave.

Nothing in this repository proves real-time performance, jitter, or long-run stability.

## License

Proprietary. See [LICENSE](LICENSE). You may use these skills with Darra EtherCAT Master; you may not redistribute modified versions as your own.
