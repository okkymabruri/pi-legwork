# Architecture

One idea, drawn: **the churn stays on the right of the line; only evidence
crosses back.**

```mermaid
flowchart LR
    subgraph caller["Caller context — expensive, quota-limited"]
        A["Agent<br/>(Claude Code, Codex, …)"]
        R["head + file path<br/><b>~40 lines</b>"]
    end

    subgraph wrap["pi-delegate"]
        W["profile · guard · watchdog<br/>thin-output extraction"]
    end

    subgraph delegate["Delegate context — cheap, plentiful quota"]
        P["pi process"]
        C["<b>the churn</b><br/>40 file reads<br/>greps · dead ends<br/>fetches · PDF pages"]
        F["full answer<br/>→ file on disk"]
    end

    A -- "task prompt" --> W
    W -- "pi --mode json -p" --> P
    P <--> C
    P --> F
    F -- "head only" --> R
    R -.->|"read in full<br/><i>only if needed</i>"| A

    style C fill:#fee,stroke:#c66
    style R fill:#efe,stroke:#6c6
```

The dotted arrow is the one that undoes the saving. Reading the whole output
file re-imports the cost just avoided, so it is the exception, not the default.

## What the wrapper actually does

```mermaid
flowchart TD
    S["pi-delegate «task»"] --> M{"model set?"}
    M -- "no" --> MX["error → --models / --doctor"]
    M -- "yes" --> PR{"profile"}

    PR -- "local" --> L["read, grep, find, ls, bash<br/><b>no network</b>"]
    PR -- "research" --> RS["web tools, read<br/><b>no bash / write</b>"]
    PR -- "full" --> FU["everything<br/><i>opt in deliberately</i>"]

    L --> G["guard extension<br/>credential paths · destructive bash"]
    RS --> G
    FU --> G

    G --> RUN["pi --mode json -p<br/>+ watchdog (600s)"]
    RUN --> EX["extract from JSONL:<br/>answer · served-by · tokens · tool counts"]
    EX --> OUT["stdout: header + head<br/>disk: full answer"]
```

## Why the profiles are split

`research` and `local` are kept apart because the combination is the danger, not
either half:

- an agent with **network egress** can send anything it read out via a URL
- an agent with **bash** can be aimed at a path or a command
- fetched web content is **untrusted input**

Separately, each is bounded. Together, an injected page has something to aim at.
Splitting removes the combination rather than policing it. `full` exists, and
asks to be chosen on purpose.

The same split prices the call: every registered tool's schema ships on every
request, so `local` costs ~3.1k input tokens and `research` ~4.7k.

## Where the guard sits, and what it is not

```mermaid
flowchart LR
    T["pi tool call"] --> H{"damage-control<br/>hook"}
    H -- "allowed" --> FS["filesystem"]
    H -- "denied" --> B["GUARD: reported<br/>run continues"]
    SP["subprocess spawned<br/>by bash"] -.->|"never passes the hook"| FS

    style SP fill:#fee,stroke:#c66
```

The hook runs **inside pi's own process**. Upstream states plainly that pi has
no built-in permission system and recommends containerization for real
boundaries.

So the dotted arrow is real: anything reaching the filesystem without passing
through a hooked tool call is outside the guard by construction. That is
proportionate for read-only surveys, where the realistic failure is a credential
path being read and pattern-matching catches it. It does not survive being
load-bearing.

## Fan-out

```mermaid
flowchart TD
    A["Agent"] --> D1["pi-delegate -o a.md"]
    A --> D2["pi-delegate -o b.md"]
    A --> D3["pi-delegate -o …"]
    D1 --> P1["pi"] --> R1["33 verdicts"]
    D2 --> P2["pi"] --> R2["33 verdicts"]
    D3 --> P3["pi"] --> R3["33 verdicts"]
    R1 --> A
    R2 --> A
    R3 --> A
```

Up to 6 concurrent, measured safe. Two rules make it work:

- **Each worker reduces.** 200 files ÷ 6 workers returning one line each ≈ 20k
  tokens. 200 individual calls ≈ 660k — worse than doing it locally.
- **Each is its own background process.** Grouped in one shell with `&` … `wait`,
  the children die when the parent is reaped, leaving `rc=0` and an empty answer
  that reads exactly like the model finding nothing.

Six is safe **because the delegates only read**. It is not a budget that
transfers to writes.
