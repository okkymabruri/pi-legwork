# Philosophy

This page explains which tasks belong on a delegate and which do not, and says
plainly when the reasoning does not apply to you.

The rule it all reduces to: **delegate evidence-gathering that compresses; keep
the judgment that has to be accountable.**

## What is actually scarce

Not tokens. Not money. **Context.**

An agent answering "which files reference the retry helper, and what for" might
read forty files to produce a ten-row table. Thirty-nine of those reads are
*churn*: work that had to happen, but that nobody needs to see again. They sit
in the context window for the rest of the session, crowding out the thing you
actually care about and degrading the reasoning that follows.

Delegation moves that churn to a separate process with its own context. The
delegate reads the forty files. You get the ten rows and a path to the rest.

**The saving comes entirely from what does not re-enter the caller's context.**
That is why this tool returns a pointer instead of a payload, and why reading
the whole output file re-imports the cost you just avoided.

## Money is a second, conditional benefit

Cost savings are real but **downstream of a condition**: your caller has to be
expensive or quota-limited, and your delegate has to be cheap or plentiful.

The measured case here was exactly that — a Claude Code subscription that runs
out, alongside a separate subscription with quota to spare. Under those
conditions, delegating spends the plentiful one.

If your caller is already cheap, you still get context isolation and lower
variance, and you pay for it in latency and duplicated inference. That may or
may not be worth it. **Do not inherit my numbers without the conditions that
produced them.**

Stated in order:

1. **Context isolation** — applies to any caller.
2. **Cost reduction** — applies only under caller/delegate quota asymmetry.

## The two gates

A task is delegable only if it passes **both**.

### Gate 1 — is churn ≫ output?

How much intermediate work does this need, relative to how long the answer is?

Delegation only wins when churn is large and output is small, because the output
comes back either way. A hundred file reads returning one table: yes. One file
read returning a long summary: no — you have paid the per-call floor to save
one read.

This gate is **economics, not capability**. A stronger delegate does not change
it. If the artifact must return to be reviewed, output ≈ work and there is
nothing to save, however good the model is.

### Gate 2 — can the output carry its own evidence?

Can the answer be checked *without redoing the work*?

This is the gate people miss, and it is why gate 1 alone gives wrong answers.
Some work is high-churn **and incompressible** — the evidence you would need to
trust the conclusion lives inside the churn that was discarded.

"Is this analysis sound" reads twenty files and returns a paragraph. Excellent
ratio. Terrible delegation — because the paragraph cannot carry what you would
need to believe it, and checking means reading the twenty files yourself.
You have paid for the work twice.

Compare "which of these forty PDFs mention X, with page number and a verbatim
quote". Same churn, same short answer — but now one claim can be spot-checked at
the cost of one page. The output carries its own evidence.

**Gate 2 is why the document rule demands locators, why research delegations
must return a source URL per claim, and why most "no" rows in the practice guide
are a "no".**

### Gate 0 — may this leave, and what can the delegate touch?

The two gates above are about *economics and verifiability*. They are not
sufficient, and treating them as the whole test was a mistake worth naming.

A task can pass both and still be wrong to delegate:

- **Confidentiality.** The delegate is a different provider. Whatever the prompt
  carries — and whatever the delegate reads — crosses that boundary. Client data,
  unpublished work, and anything under NDA fail here regardless of how good the
  churn ratio is.
- **Untrusted input.** Repository content and fetched pages can carry prompt
  injection. The delegate acts on what it reads.
- **Authority.** The default `local` profile includes `bash`. A delegate can
  write, delete, and spawn subprocesses. "Read-only" describes the tasks people
  send, not a boundary the tool enforces — use `-p readonly` for the enforced
  version.

Gate 0 comes first because it is a veto, not a trade-off. The other two decide
whether delegation *pays*; this one decides whether it is *allowed*.

## What this buys, and what it costs

| | |
|---|---|
| **Buys** | Caller context stays clean. Cheap quota absorbs the churn. Cost variance drops sharply — the measured direct runs varied 67% run-to-run, delegated runs 0.6% |
| **Costs** | A per-call floor (~3.1k input tokens local, ~4.7k with web tools). Latency. A delegate that cannot see your conversation, so every prompt must carry its own context |

## The line on writes

This tool is not *for* writing to your working tree. That is a design position,
not a missing feature. (It is also not a guarantee: the default `local` profile
carries `bash`, so a delegate can write. `-p readonly` is the enforced version.)

If the delegate returns a diff, you must read the diff to trust it, and reading
it costs what writing it would have. Gate 1 fails.

The obvious counter is: let the delegate write the files itself and return only
"tests passed", so nothing comes back. That fails gate 2. **"Tests passed"
proves the code runs; it does not prove the answer is right.** For analysis,
prose, or configuration there is often no oracle at all, and a passing linter
certifies nothing that matters.

**Nested subagents** are excluded for a related reason. Top-level fan-out
already gives parallelism, and nesting costs the observability that tells you
which model produced which claim.

There is a narrow shape that passes both gates:

> Delegate writes only where the check is a **command**, not a **read**.

Bulk mechanical edits qualify — the same change across forty files, verified by
a count rather than by reading. That is a hypothesis under test here, not a
shipped feature. It is not in this tool, and it will not be added on the
strength of one task class.

## Honest boundaries

The claims this repo makes, and the ones it refuses to:

- **Measured, on my own setup**: one task class, n=2 per arm, roughly a quarter
  the caller tokens, identical answers. An existence proof for that shape of
  work. **Not** a general cost reduction, and the raw runs are not published --
  `benchmark/` is here so you can measure your own.
- **The guard is a policy hook, not a sandbox.** Upstream pi states it has no
  permission system and recommends containerization. Anything reaching the
  filesystem without passing through a hooked tool call is outside the guard.
- **Only Claude Code was measured.** Other hosts can run the command; the
  economics depend on their own quota asymmetry.
- **The delegate is a different model.** Identical answers on one benchmark is
  not general equivalence.

Two more, learned the hard way:

- **Token accounting is easy to get wrong.** Sum per-request `input + output`.
  Do not sum a cumulative `totalTokens` field, which folds in cache and
  reasoning counters — that inflated this project's own figures ~1.5× until it
  was caught.
- **macOS bash 3.2 aborts on empty array expansion under `set -u`.** Array
  arguments need `${arr[@]+"${arr[@]}"}`. One tool profile had never run because
  of it.

A tool that overstates what it proved is worse than one that proves less, because
you cannot tell which parts to trust.

## Where this sits among similar tools

Most published integrations in this space are MCP-based and write-capable. They
exist for parallelism, so results flow back through the protocol.

This one is the other kind. It sits on the caller's side and returns a pointer,
because the goal is protecting context rather than adding workers.

Note the direction, since several unrelated projects share the command's name:
this delegates **to** pi from the caller's side. Projects called `pi-delegate`
are generally pi *extensions* delegating **from** pi to child agents.
