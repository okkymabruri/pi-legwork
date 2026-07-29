# Integrations

`pi-delegate` is a shell command. Any agent that can run a shell command can use
it — nothing here is host-specific.

What *is* host-specific is how the agent learns **when** to reach for it. That is
one instruction file per host, not an abstraction layer.

| Host | File | Status |
|---|---|---|
| Claude Code | [`../skills/pi-delegate/SKILL.md`](../skills/pi-delegate/SKILL.md) | **Measured** — 0.23× caller tokens on a grep-heavy task |
| Codex CLI | [`codex/AGENTS.md`](codex/AGENTS.md) | **Fires correctly; no measured saving** — see below |
| Anything else | see below | Untested |

### What the Codex tests showed

Codex CLI 0.145.0 reads the block and acts on it. Across four runs it delegated
without being told to in the prompt, chose `-p readonly` on its own, delegated
*before* doing its own work, then spot-checked. On one run it stated its
reasoning in the block's own terms: *"this is exactly the kind of high-churn,
evidence-checkable survey covered by the repository's delegation rule."*

Answers were correct every time.

**It saved nothing.** Two task shapes, one run per arm, 60-file corpus:

| Task | Baseline | Delegated | Ratio |
|---|---:|---:|---|
| Greppable survey ("which files reference X") | 27,320 | 26,231 | 0.96 |
| Read-heavy classification ("group all 60 by stage") | 46,638 | 46,403 | 0.995 |

The reasons differ, and both are the gates working rather than the tool failing:

- The greppable task has **no churn to move**. Codex answered with ripgrep in
  two tool calls. File count is not churn.
- The classification task has churn but **irreducible output**: the answer is a
  list of all 60 modules, so what comes back is nearly as large as the work.
  Gate 1 fails on the output side. A follow-up run after adding an explicit
  "cap the output shape" instruction did not improve it (52,310 tokens), which
  is the expected result if the output genuinely cannot be reduced.

**So Codex support is real but unproven as an economy.** The context benefit
still applies — the reads happen elsewhere. Whether tokens drop depends on your
caller's pricing and quota, and on finding tasks where the answer is genuinely
much smaller than the work. None of the shapes tested here were.

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
   resident context. Link `skills/pi-delegate/WHEN-TO-DELEGATE.md` from it so the agent
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
