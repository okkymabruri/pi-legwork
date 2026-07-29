---
name: pi-delegate
description: Run high-churn exploration on a cheaper agent and keep only the answer. Use when a task needs many file reads or greps but returns a short answer — codebase surveys, "which files reference X", inventories and gap-finding, git-history archaeology, log and data scans, web research with sources, screening or extracting from PDFs and decks. Also use for an independent second opinion on a hard decision.
---

# Delegating research to a cheaper agent

`pi-delegate` runs a read-only task in a separate agent session and returns a
short head plus a file path, so the file reads and greps it did never enter this
context.

```bash
pi-delegate "which files under src/ reference the retry helper, and what for"
```

Run it with `run_in_background: true` — a call takes ~25–60s.

## Gate 0 — is this allowed to leave?

Before the economics: the delegate is a **different provider**, so the prompt and
whatever it reads cross that boundary. Client data, unpublished work, anything
under NDA: do not delegate, whatever the ratio.

Also note the authority: the default `local` profile includes `bash`, so a
delegate *can* write and delete. Pass `-p readonly` (no bash, no network) when
the task only needs reading — that is the enforced version.

## Two gates

Once gate 0 is clear, delegate only when **both** pass.

1. **Churn ≫ output** — many reads, short answer. The answer returns either way,
   so only the churn is saved.
2. **The output carries its own evidence** — it can be checked without redoing
   the work. Paths, line numbers, commit SHAs, source URLs, page numbers.

Gate 2 is the one that gets missed. "Is this analysis sound" reads twenty files
and returns a paragraph — great ratio, but the paragraph cannot carry what you
would need to believe it, so checking means reading the twenty files yourself.

Both gates are economics and verifiability. Neither says the delegate is weak.

**For the full decision table — ~18 task shapes with the gate each one fails —
read `WHEN-TO-DELEGATE.md` (beside this file) before delegating anything not obviously
covered above.**

## Writing the prompt

The delegate sees the prompt and the working directory's `AGENTS.md`/`CLAUDE.md`.
It never sees this conversation, so the prompt carries everything.

- Name exact paths.
- **Cap the output shape**: "one line per file", "a markdown table", "just the
  list", "one word". Asking for a full inventory with evidence for every item
  returns an answer as large as the work, and the saving disappears.
- For research, require a source URL per claim.
- For documents, require a page number and a verbatim quote per claim.

## Fan out

Up to 6 concurrent, each its own background call, each writing to its own `-o`
path.

```bash
pi-delegate -o /tmp/a.md "survey X"
pi-delegate -o /tmp/b.md "survey Y"
```

Each worker must **reduce** — say "one line per file" explicitly. A worker
returning payloads instead of verdicts relocates the cost rather than saving it.

Keep them as separate background calls. Grouping them in one shell with `&` …
`wait` kills the children when the parent is reaped, leaving `rc=0` and an empty
answer that reads exactly like the model finding nothing.

## Second opinion

```bash
pi-delegate -2 "independent read on this decision: <the whole problem>"
```

Bought for **independence**, not savings — the delegate having none of this
conversation is the point. It runs a stronger model with project context off.

Trigger it unprompted when the decision is architectural or hard to reverse,
when three turns have passed without converging, when you are about to invalidate
finished work, or when being wrong costs more than the call.

Put the **whole** problem in the prompt. Half the context yields a confident
answer to the wrong question.

## Reading the result

The header prints `served by:` — the model that actually answered, which differs
from `requested:` when a fallback chain is configured. Scale verification to it.

Read the head. Reading the whole output file re-imports the cost just avoided.

A `GUARD:` line means the safety hook denied a path — report it as a finding.

Verification is wrong about as often as the delegate is. Treat a disagreement as
a question about both sides.

## Flags

| Flag | Use |
|---|---|
| `-o PATH` | durable output path (use whenever fanning out) |
| `-p readonly` | no bash: cannot mutate anything |
| `-p research` | web tools, no bash/write |
| `-nc` | skip the cwd's `AGENTS.md`/`CLAUDE.md` |
| `-s ID` | resumable session for follow-ups |
| `-f FILE` | long task text from a file |
| `--models` | what models are configured |
| `--doctor` | check the install |
