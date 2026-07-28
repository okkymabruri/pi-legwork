# pi-legwork

**Delegate the legwork. Keep the judgment.**

Your coding agent burns its context on *churn* — forty file reads to produce a
ten-row table. `pi-legwork` runs that churn on a cheaper agent
([pi](https://github.com/badlogic/pi-mono)) and returns a **pointer, not a
payload**: a short head plus a file path.

Measured **0.23× caller tokens** on a grep-heavy task, identical answers.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

```bash
pi-delegate "which files under src/ reference the retry helper, and what for"
```

> **Case study with code attached, not a maintained product.** Published because
> the measurement and the boundaries seemed worth writing down. Unsupported
> reference artifact — issues and PRs may go unanswered. Fork it freely.

---

## Install

Requires [pi](https://github.com/badlogic/pi-mono) on `PATH`, plus `jq`.

```bash
git clone https://github.com/<you>/pi-legwork && cd pi-legwork
install -m755 pi-delegate.sh ~/.local/bin/pi-delegate

pi-delegate --models          # what models pi already has configured
export PI_DELEGATE_MODEL='<provider/model>'
pi-delegate --doctor          # checks the whole install, says what is missing
```

There is **no default model** — the right delegate depends on which quota you
have spare. See [docs/PROVIDERS.md](docs/PROVIDERS.md).

Optional but recommended — the guard:

```bash
cp damage-control-rules.json ~/.pi/
# then register extensions/damage-control.ts in your pi settings
```

Read [the threat model](#the-guard-is-not-a-sandbox) before relying on it.

## Use

```bash
pi-delegate "task"                       # survey, grep sweep, inventory
pi-delegate -o /tmp/out.md "task"        # durable output path
pi-delegate -p readonly "task"           # no bash: cannot mutate anything
pi-delegate -p research "look up X"      # web tools, no bash/write
pi-delegate -2 "<the whole problem>"     # independent second opinion
pi-delegate -s audit-1 "follow-up"       # resumable session
pi-delegate -nc "task"                   # skip the cwd's AGENTS.md/CLAUDE.md
```

| Flag | |
|---|---|
| `-m MODEL` | override the delegate model |
| `-f FILE` | long task text from a file |
| `--models` | list configured models |
| `--doctor` | check the install |

Run it in the background — a call takes ~25–60s. Fan out to **6 concurrent**,
each its own background process with its own `-o` path.

## When to delegate

Two gates. **Both** must pass.

1. **Churn ≫ output.** Many reads, short answer. The answer returns either way,
   so only the churn can be saved.
2. **The output carries its own evidence.** It can be checked without redoing the
   work — paths, line numbers, commit SHAs, source URLs, page numbers.

Gate 2 is the one people miss. *"Is this analysis sound"* reads twenty files and
returns a paragraph: great ratio, but the paragraph cannot carry what you would
need to believe it, so checking means reading the twenty files yourself.

**→ [`skills/pi-delegate/WHEN-TO-DELEGATE.md`](skills/pi-delegate/WHEN-TO-DELEGATE.md)** — the full
table, ~18 task shapes with the gate each one fails.

**→ [`PHILOSOPHY.md`](PHILOSOPHY.md)** — why context, not money, is the scarce
resource, and what conditions the cost saving depends on.

**→ [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — diagrams of what crosses
the context boundary and what does not.

## Agent integrations

The command is plain bash; any agent that can run a shell command can use it.
What differs per host is *how the agent learns when to reach for it* — one
instruction file each, no abstraction layer.

| Host | Status |
|---|---|
| [Claude Code](skills/pi-delegate/SKILL.md) | **Measured** |
| [Codex CLI](integrations/codex/AGENTS.md) | Fires correctly; savings unmeasured |
| [Anything shell-capable](integrations/README.md) | Untested |

## The measurement

Grep-heavy locate task, n=2 per arm:

| | Caller tokens |
|---|---:|
| Direct | 257,970 |
| Delegated | 60,453 |

Ratio **0.23**, worst case 0.31, answers identical. Variance also collapsed —
direct runs varied 67% run-to-run, delegated runs 0.6%.

The decision rule was fixed *before* any data existed: delegated < 0.6 × direct
on at least one task class, with equal answers. One task class cleared it.

**Read it as one task class, n=2 — not a general claim.**

## Profiles, and what "read-only" actually means

| Profile | Tools | Can mutate? | Floor |
|---|---|---|---|
| `readonly` | `read,grep,find,ls` — no bash, no network | **No — enforced** | ~3.1k |
| `local` (default) | `+ bash`, no network | **Yes** | ~3.1k |
| `research` | web tools + `read`, no bash/write | No | ~4.7k |
| `full` | everything — opt in deliberately | Yes | ~4.7k |

**Read this before believing the phrase "read-only" anywhere else in this repo.**
The default profile carries `bash`. A delegate under `local` that is asked to
overwrite a file will do it — verified, not theorised. Read-only under `local` is
a property of *which tasks you send*, not a boundary the tool enforces.

Use `-p readonly` when you want the guarantee. It is enough for surveys, greps,
and file reads, and it costs nothing extra.

`research` and `local` are kept apart for a different reason: an agent holding
both network egress and bash can be aimed at something by an injected page, since
fetched web content is untrusted input. Splitting removes the combination rather
than policing it.

## The guard is not a sandbox

`extensions/damage-control.ts` denies reads of credential paths and blocks
destructive bash patterns. It is a **policy hook inside the agent's own
process**. Upstream is explicit:

> "Pi does not include a built-in permission system for restricting filesystem,
> process, network, or credential access. By default, it runs with the
> permissions of the user and process that launched it."
> — [badlogic/pi-mono](https://github.com/badlogic/pi-mono)

Upstream recommends containerization for real boundaries. Anything reaching the
filesystem without passing through a hooked tool call — a subprocess spawned by
`bash`, most obviously — is outside the guard by construction.

Proportionate for read-only surveys. It does not survive being load-bearing.

## Deliberately not included

**Writing to your working tree.** If the delegate returns a diff you must read
the diff, so gate 1 fails. If it writes files and returns "tests passed", gate 2
fails — that proves the code runs, not that the answer is right, and for
analysis or prose there is often no oracle at all.

There is a narrow shape that passes both — *delegate writes only where the check
is a command, not a read* — but it is a hypothesis under test, not a feature.

**Nested subagents.** Top-level fan-out already gives parallelism, and nesting
costs the observability that tells you which model produced which claim.

## Positioning

Most published integrations in this space are MCP-based and write-capable, built
for parallelism: results flow back through the protocol. This is the other kind
— a caller-side wrapper built for context economics, where only a
pointer flows back.

Note the direction, because several unrelated projects share the command's name:
this delegates **to** pi from the caller's side. Projects called `pi-delegate`
are generally pi *extensions* delegating **from** pi to child agents.

## Known limits

- One task class measured, n=2 per arm. Not a general cost reduction.
- The delegate is a different model; identical answers on one benchmark is not
  general equivalence.
- Cost savings require caller/delegate quota asymmetry. Context isolation does
  not, but has its own price in latency.
- Token accounting is easy to get wrong: sum per-request `input + output`, not a
  cumulative `totalTokens` field — that inflated this repo's own figures ~1.5×
  until it was caught.
- macOS bash 3.2 aborts on empty array expansion under `set -u`; array args need
  `${arr[@]+"${arr[@]}"}`.

## License

MIT — see [LICENSE](LICENSE).
