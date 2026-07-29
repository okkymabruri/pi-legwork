# When to delegate, and when not to

The operating guidance an agent is given alongside the tool. This is the
transferable half of the project — the wrapper is ~300 lines of bash; knowing
*which* tasks pay is what makes it worth having.

> **Working practice as of 2026-07, not universal policy.** Derived from one
> person's measurements on one workload. The reasoning is stated throughout so
> you can tell which parts transfer to yours. Unsupported reference artifact —
> no maintenance promised.

## The two gates

Every decision below is derived from these. See [PHILOSOPHY.md](https://github.com/okkymabruri/pi-legwork/blob/main/PHILOSOPHY.md)
for why they exist.

**Gate 1 — churn ≫ output.** Is the intermediate work (reads, greps, dead ends)
large relative to the length of the answer? The output returns to the caller
either way, so only the churn can be saved.

**Gate 2 — the output carries its own evidence.** Can the answer be verified
*without redoing the work*? If checking it means repeating what the delegate did,
you pay twice.

**Both must pass.** Gate 1 alone gives wrong answers, because some work is
high-churn *and* incompressible.

## The table, and which gate decides each row

| Shape | Verdict | Why |
|---|---|---|
| "Does doc X still match code Y" / stale-claim sweep | **Yes — best-proven** | Both. Many reads, small table, each claim cites file and line. A 14-row audit came back 10 sound, 1 novel-and-significant |
| "Which files reference X, and what for" | **Yes** | Both. The paths in the answer *are* the evidence |
| "Find every A with no matching B" (gap-finding) | **Yes** | Both. The best-measured case here; each hit checkable with one grep |
| "When did X change and why" across git history | **Yes** | Both. Thousands of commits in, a paragraph out, commit SHAs carry the proof |
| "Which of these 40 files touch X" (debug **search**) | **Yes**, search only | Gate 1 passes for the hunt. **Keep the diagnosis** — that is judgment |
| "Scan these 400 log files for the pattern" | **Yes** | Both. Line numbers make it checkable |
| "Look up X on the web, report one number + source" | **Yes** | Both — *provided* you require the source URL. Without it, gate 2 fails |
| "Compare N products/models, cite sources" | **Yes** | Both, same condition: a URL per claim makes verification cheap |
| "Extract the table / captions / citations from a PDF" | **Yes — best ratio** | Gate 1 strongly: image tokens *are* the churn. Gate 2 **only with locators** — page number plus verbatim quote |
| "Which of these 40 papers mention X" | **Yes** | Both. Screening at scale, each hit checkable at one page |
| "Independent read on this decision" (`-2`) | **Yes — different reason** | Passes neither gate. Bought for independence. See below |
| "Read this one file and summarise it" | **Marginal** | Gate 1 fails — one read, long answer. You pay the per-call floor to save one read |
| "Is this paper's methodology sound" | **No** | Gate 2 fails. The evidence for the verdict is the reading that got discarded |
| "Is this analysis right" | **No** | Gate 2 fails, same shape |
| "Write this function, return the code" | **No** | Gate 1 fails. The diff returns to the caller anyway |
| "Write the commit message" | **No** | Gate 1 fails hardest — you already hold the diff. Output ≈ input, zero churn |
| "Review this diff for bugs" | **No** | Gate 1 fails: output as long as the work |
| "Ask two models the same factual question" | **No** | Neither gate. Doubles output, reduces no churn — and correlated models are not independent draws, so their agreement is weak evidence dressed as strong |

Note what the "no" rows have in common: none of them say the delegate is too
weak. They are economics and verifiability, which a stronger model does not
change.

## Second opinion — the row that passes neither gate

```bash
pi-delegate -2 "independent read on this decision: <the whole problem>"
```

Bought for **independence**, not savings. The delegate having none of the
caller's conversation is normally the weakness; here it is the entire point.

Three rules make it work:

1. **Put the whole problem in the prompt.** Half the context yields a confident
   answer to the wrong question — worse than not asking.
2. **Use a stronger model, here and nowhere else.** One call, short answer, so
   quality costs almost nothing — and weak confident agreement is worse than
   silence.
3. **Change the contract, not just the model.** A delegate told only to be terse
   will agree tersely. The prompt must license disagreement outright: lead with
   the verdict; if you disagree say so first; name the missing piece rather than
   guessing around it.

### Trigger it without being asked

Complexity is exactly when a second read is worth 60 seconds, and exactly when
nobody remembers to ask for one. Run `-2` unprompted when:

1. The decision is architectural or hard to reverse — schema, published
   interface, data model, anything that becomes someone else's dependency.
2. Three or more turns have passed on the same problem without converging.
3. You are about to commit to an approach that invalidates work already done.
4. Being wrong would cost more than the call does.

Do **not** use it as a redundant check on a factual question you can verify
directly.

## Map-reduce — batch, or don't bother

```
200 files ÷ 6 workers, each returning ~33 one-liners  →  6 calls ≈ 20k tokens
200 files, one call each                              →  200 × 3.3k = 660k  ✗
```

Each worker must **reduce**. A worker returning 33 payloads instead of 33
verdicts just relocates the cost — say "one line per file" explicitly.

There is a hard per-call input floor (~3.1k local, ~4.7k with web tools) because
every registered tool's schema ships on every request. Batch related questions
into one delegation; do not fire many small ones.

## Fan out, up to 6

Six concurrent delegations is measured safe. Launch each as its **own**
background process.

**Do not** put them in one shell with `&` … `wait`. When that parent shell is
reaped the children die mid-run, leaving `rc=0` and an empty answer — which looks
exactly like the model finding nothing. Observed once at a cost of 4 lost audits
out of 6.

Six is safe **because the delegates only read**. It is not a budget that
transfers to writes: no surveyed project runs concurrent write-capable delegates
against one repository with a documented isolation mechanism.

## Documents — extraction yes, judgment no

The best ratio available, and the clearest illustration of gate 2.

Gate 1 is overwhelming: a 30-page paper costs a fortune in input tokens and the
answer is a few lines. But verification is **asymmetric**:

| | cost to verify |
|---|---|
| text survey | cheap — one `grep` |
| document extraction | **exactly the cost you avoided** — you must read the document |

So **require locators**: every claim carries a page or slide number and a short
verbatim quote. That is what moves the task across gate 2. Without them, a
confident wrong extraction is unfalsifiable short of doing the work yourself.

| Delegate | Do not delegate |
|---|---|
| "Which of these 40 PDFs mention X" | "Is the argument sound" |
| "Extract the results table" | "Is the methodology valid" |
| "Every figure caption + page number" | "Rate this deck's design" |
| "Slides missing the required footer" | Anything you would act on without re-reading |

Extraction and screening, never judgment.

## Verification rules

1. **Scale effort to the tier that served.** If your setup falls back between
   models, requested and serving model differ by design. Read which one actually
   answered before deciding how hard to check.
2. **Read the head, not the file.** Reading the full output re-imports the cost
   you just avoided.
3. **A guard block is the hook working**, not the model failing. Report it; never
   re-run to get past it.
4. **The delegate has none of your conversation.** It *does* read the working
   directory's context files unless you pass `-nc`. The common failure is missing
   context, not weak reasoning.
5. **Expect the verification to be wrong too.** On two occasions here the
   delegate was right and the check was wrong — a grep whose `--include` list
   omitted a file type, and a file count that excluded `node_modules` when the
   question didn't. Treat disagreement as a question about both sides.
6. **Name exact paths and state the output shape** ("a markdown table", "just the
   list", "one word"). For research, require a source URL per claim.

## Profiles are a security boundary

- **`local`** — read/grep/find/ls/bash, **no network.** Nothing to exfiltrate
  through.
- **`research`** — web tools + read, **no bash/edit/write.** Fetched web content
  is untrusted input; an injected page has nothing to aim at.
- **`full`** — both at once. Opt in deliberately, never by default.

Registering web tools puts a network-egress channel in the same agent that holds
bash. Two consequences appear only in combination: anything the agent read can
leave via a URL query string, and a fetched page can instruct the agent to read a
path or run a command. Splitting the tool set by job removes the combination
rather than policing it.

**The guard is defense in depth, not a sandbox** — see the threat model in the
[README](https://github.com/okkymabruri/pi-legwork/blob/main/README.md).

## Out of scope

| Work | Which gate it fails |
|---|---|
| Writing code, returning a diff | Gate 1 — output ≈ work |
| Writing commit messages | Gate 1 — you already hold the diff |
| Reviewing a diff for bugs | Gate 1 — output as long as the work |
| Multi-model quorum on one fact | Both — doubles output, reduces no churn |
| Anything writing to the working tree | Gate 2 — no oracle, and the guard protects against a *reading* agent |
| Reading credential files "to check structure" | Blocked by the guard. Do not route around it |
| Work needing the caller's conversation | The delegate cannot see it |

## Setup and troubleshooting

```bash
pi-delegate --models    # what models pi actually has configured
pi-delegate --doctor    # checks the install and says what is missing
```

`--doctor` checks in order: pi on PATH → models configured → `PI_DELEGATE_MODEL`
valid → second-opinion model → guard rules present. Each failure says what to do
next. See [docs/PROVIDERS.md](https://github.com/okkymabruri/pi-legwork/blob/main/docs/PROVIDERS.md) to configure a model.
