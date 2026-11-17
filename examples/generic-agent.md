# Using these skills with any agent framework

Each `SKILL.md` is a self-contained instruction document. It is plain Markdown in UTF-8
with YAML front matter, it has no runtime dependency, and nothing in it needs to execute
for the agent to read it.

## Three ways to wire it up

**1. System prompt fragment.** Strip the YAML front matter and paste the body into the
system prompt for a session that will touch EtherCAT. Simplest, but costs context even when
the skill is not used.

**2. On-demand file read (recommended).** Give the agent a file-read tool scoped to this
repository and tell it the four paths. It reads the matching `SKILL.md` only when the
request calls for it. Costs nothing until used, and the agent always sees the current text.

**3. Router on the description.** Parse the `description` field of each file and match
incoming requests against its trigger words (EtherCAT, DENI, PDO, install, verify, ...).
Inject the matched file as a tool result or a system message.

## Rules the skills assume

- **Exactness.** API names, package names, parameter names, exit codes, and state names are
  literal. Do not normalize them into the conventions of your own framework, and do not
  let the model paraphrase them. `SetState(EcState.OP, out err)` is the call; `EcState.OP`
  is the enum value.
- **Read the rules file first.** `darra-ethercat` instructs the agent to fetch
  <https://ethercat.darra.xyz/ai-prompts.txt> before writing any code, and to stop rather
  than invent an interface if it cannot be reached. Grant outbound HTTPS to
  `ethercat.darra.xyz` and `download.darra.xyz`, or the skill will correctly refuse.
- **Human confirmation before install.** `darra-runtime-install` requires the agent to
  explain what will happen (driver replacement, possible real-time core reservation,
  reboot) and get an explicit go-ahead. Do not pre-authorize `--silent --install` in an
  auto-approving tool policy.
- **No automatic reboot.** Exit code 3010 means success with a reboot pending. The agent
  reports it; the user decides when to reboot.
- **Three-state scan verdict.** `null` = not measured, `0` = measured empty bus, `N > 0` =
  measured N slaves. These are not interchangeable, and "not measured" must never be
  reported as "no slaves".
- **Honest scope.** `darra-verify` proves the SDK loads, adapters enumerate, and the scan
  verdict is well-formed. It proves nothing about real-time behavior or about slaves
  reaching OP.

## Minimum tool surface

| Skill | Tools it needs |
|---|---|
| `darra-ethercat-windows` | HTTP GET (docs), file write, shell (run the installer, then `Get-Service` / `Get-AuthenticodeSignature`) — install steps user-gated |
| `darra-ethercat` | HTTP GET (docs), file write (the program it generates) |
| `darra-runtime-install` | HTTP GET + SHA256 (download and check), shell (run the installer) — user-gated |
| `darra-verify` | file write, shell (`dotnet new` / `add package` / `run`) |

No network access to internal hosts, no credentials, and no configuration on your side are
required.
