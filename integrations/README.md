# Integrations

`pi-delegate` is a shell command. Any agent that can run a shell command can use
it — nothing here is host-specific.

What *is* host-specific is how the agent learns **when** to reach for it. That is
one instruction file per host, not an abstraction layer.

| Host | File | Status |
|---|---|---|
| Claude Code | [`claude-code/SKILL.md`](claude-code/SKILL.md) | **Measured** — 0.23× caller tokens on a grep-heavy task |
| Codex CLI | [`codex/AGENTS.md`](codex/AGENTS.md) | **Fires correctly**, savings unmeasured — see below |
| Anything else | see below | Untested |

### What the Codex test showed

Codex CLI 0.145.0, given the `AGENTS.md` block and a survey task, chose to
delegate on its own: it ran `pi-delegate -o /tmp/…`, the delegate did
`1×find 2×grep`, and 544 bytes came back.

So the instruction block works — Codex reaches for the tool without being told
to in the prompt. **The economics were not tested**: the corpus was nine small
files, which fails gate 1, and Codex spent about the same either way. That is
the expected result at that size, and it is why the row above says *fires
correctly* rather than *saves tokens*.

## Any shell-capable host

Three things to wire up:

1. **Install the command** — see the [README](../README.md). Confirm with
   `pi-delegate --doctor`.
2. **Tell the agent when to use it.** Put the two gates and the command into
   whatever standing-instruction mechanism your host has — a system prompt, a
   rules file, a `AGENTS.md`. The block in
   [`codex/AGENTS.md`](codex/AGENTS.md) is written to be copied as-is; it does
   not mention Codex.
3. **Point at the full table.** The standing block stays short because it is
   resident context. Link `practice/WHEN-TO-DELEGATE.md` from it so the agent
   can reach the ~18-row decision table when a task is not obviously covered.

## What transfers, and what does not

Two separate claims, and only one of them is general:

- **Context isolation transfers.** Any caller benefits from keeping forty file
  reads out of its own window. This is the mechanism the tool is built on.
- **Cost reduction is conditional.** It requires your caller to be expensive or
  quota-limited *and* your delegate to be cheap or plentiful. The measured 0.23×
  came from a Claude Code subscription that runs out alongside a separate
  subscription with quota to spare.

If your caller is already cheap, you get context isolation and lower variance,
and you pay latency and duplicated inference for it. That trade may still be
worth it — but measure it rather than inheriting a number from a different setup.

Only Claude Code has been benchmarked. Treat every other row in the table above
as plausible and unverified.
