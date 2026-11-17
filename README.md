# Darra EtherCAT Skills

Agent skills for **Darra EtherCAT Master**: write master programs, install the runtime, verify a live bus.

These are plain Markdown instruction files. There is no build step and nothing to compile — an agent reads the relevant `SKILL.md` and follows it.

> The skill text is written in Chinese. Each file's YAML front matter carries the machine-readable English name plus the Chinese trigger words it matches on.

---

## Skills

| Skill | What it solves | Reach for it when |
|---|---|---|
| [`darra-ethercat`](skills/darra-ethercat/SKILL.md) | Writing master programs in C#, Java, Python, C, C++, or Rust: DENI configuration, build/init order, the state machine up to OP, PDO struct mapping, SDO, CiA 402 servo control, DC. | The task is to write or review master-side code. |
| [`darra-runtime-install`](skills/darra-runtime-install/SKILL.md) | Downloading and silently installing the runtime: fixed download URL, SHA256 check, silent install / uninstall, exit-code interpretation (3010 = success, reboot pending), upgrade-in-place semantics, and the "never auto-reboot, never install without confirmation" boundary. | The machine needs the runtime, or an install / upgrade / uninstall question comes up. |
| [`darra-verify`](skills/darra-verify/SKILL.md) | Proving the SDK actually works after install: build a small C# console app, enumerate adapters, quick-scan each port, emit machine-readable JSON with a three-state scan verdict. | Someone asks "did it install correctly?" or "why does it scan nothing?". |

## How to use

- **Claude Code** — see [`examples/claude-code.md`](examples/claude-code.md).
- **Any other agent framework** — see [`examples/generic-agent.md`](examples/generic-agent.md).

Short version: put each skill directory under your agent's skills folder, or feed the matching `SKILL.md` into the system prompt when that kind of work comes up. The skill's `description` field is the routing key — it lists the trigger words.

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

`darra-verify` proves three things: the SDK loads, the adapters enumerate, and the scan verdict is one of three states — `null` = not measured, `0` = measured empty bus, `N > 0` = measured N slaves.

It does not prove real-time performance, and it does not prove that slaves reach OP. Neither does anything else in this repository.

## License

Proprietary. See [LICENSE](LICENSE). You may use these skills with Darra EtherCAT Master; you may not redistribute modified versions as your own.
