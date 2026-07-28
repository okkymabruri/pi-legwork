# pi-delegate — snippet for Codex CLI

Paste this block into your `AGENTS.md`. Codex reads that file as standing
instructions, so keep it short: it is resident context on every request.

<!-- pi-legwork:start -->
## Delegating legwork

`pi-delegate` runs high-churn exploration on a cheaper agent and returns a
short head plus a file path, so the intermediate reads never enter this context.

```bash
pi-delegate -o /tmp/out.md "which files under src/ reference the retry helper, and what for"
```

First: the delegate is a **different provider**, so anything in the prompt or
read by it crosses that boundary — never delegate confidential work. The default
profile includes `bash` and *can* write; use `-p readonly` when the task only
needs reading.

Then delegate when **both** hold:

1. **Churn ≫ output** — many reads or greps, short answer.
2. **The output carries its own evidence** — checkable without redoing the work
   (paths, line numbers, commit SHAs, source URLs, page numbers).

Good shapes: codebase surveys, "which files reference X", gap-finding,
git-history archaeology, log scans, web research with sources, screening PDFs.

Keep locally: writing code, reviewing diffs, commit messages, and any judgment
call whose evidence is the reading itself ("is this analysis sound").

The delegate sees only the prompt and the working directory's context files, so
name exact paths and state the output shape you want. Read the head; open the
file only when the head is insufficient.

For a hard or hard-to-reverse decision, get an independent read:
`pi-delegate -2 "<the whole problem>"` — put the entire problem in the prompt.

Setup: `pi-delegate --doctor`.
<!-- pi-legwork:end -->

## Notes

- **Verified on Codex CLI 0.145.0**: given this block and a survey task, Codex
  chose to delegate on its own — no prompting toward the tool. The savings were
  not measured; the test corpus was small enough to fail gate 1.
- Only the Claude Code integration has **measured** savings. The context benefit
  applies to any caller; the cost benefit depends on your caller being expensive
  or quota-limited while the delegate is cheap.
- Codex also supports `hooks.json` (`PreToolUse`, `PostToolUse`). A hook is not
  required for this — the instruction block above is enough, and a hook would
  add a failure mode without adding capability.
