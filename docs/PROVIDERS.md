# Configuring a delegate model

> Do not have pi yet? `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`,
> or follow [pi.dev](https://pi.dev). Docs: [pi.dev quickstart](https://pi.dev/docs/latest/quickstart).

`pi-delegate` needs one model set in `PI_DELEGATE_MODEL`. It does not ship a
default, because the right delegate depends on which quota *you* have spare —
that asymmetry is the whole economic argument.

Check what you have:

```bash
pi-delegate --models     # passes through to `pi --list-models`
pi-delegate --doctor     # checks the whole install and says what is missing
```

## What makes a good delegate

The delegate does high-churn reading and returns short answers. That workload
rewards different things than your main agent does:

| Matters | Why |
|---|---|
| **Large context window** | Surveys pull in a lot before reducing it |
| **Terseness** | A verbose model costs you on read-back. Measured: two models gave identical answers to one task in 60 vs 1,498 characters |
| **Quota you are not otherwise spending** | The saving is asymmetry. A delegate on the same subscription as your caller saves nothing |
| **Tool-use reliability** | It must grep and read files without getting lost |

Raw reasoning strength matters **less** than you would expect, because the
[two gates](../PHILOSOPHY.md) already exclude the work where judgment decides the
answer. What you are buying is thorough searching and honest reporting.

## Adding a provider to pi

pi reads providers and models from `~/.pi/agent/`. The general shape:

1. **Get an API key** from the provider.
2. **Make it available**, either as the provider's standard environment variable
   or via `pi`'s own settings.
3. **Confirm the model is visible** — this is the step people skip:

```bash
pi --list-models
```

A model present in a provider's catalogue is not usable until pi can see it
here. If it is missing, pi will not route to it however correct the name looks.

4. **Point the wrapper at it:**

```bash
export PI_DELEGATE_MODEL='<provider>/<model>'
pi-delegate --doctor
```

Put the export in your shell profile so it survives a new terminal.

### Worked example

```bash
$ pi --list-models
provider   model                    context  max-out  thinking  images
myprov     myprov/fast-1m           1M       128K     yes       yes
myprov     myprov/heavy             256K     64K      yes       yes

$ export PI_DELEGATE_MODEL=myprov/fast-1m
$ pi-delegate --doctor
ok   pi on PATH (/opt/homebrew/bin/pi)
ok   2 model(s) configured in pi
ok   PI_DELEGATE_MODEL=myprov/fast-1m is configured
note PI_DELEGATE_SO_MODEL unset -- -2 will reuse PI_DELEGATE_MODEL.
          A stronger model here is worth it: weak agreement is worse than none.
ok   guard rules at ~/.pi/damage-control-rules.json

Ready.
```

## The second-opinion model

```bash
export PI_DELEGATE_SO_MODEL='<provider>/<a stronger model>'
```

`-2` is the one shape that does **not** qualify on churn-to-output. It is one
call returning a short answer, bought for independence rather than savings — so
a stronger model costs almost nothing here, and a weak model's confident
agreement is worse than not asking at all.

Left unset, `-2` reuses `PI_DELEGATE_MODEL` and still works. It is just worth
less.

## Fallback chains

Some routers expose a chain as a single model id, filling one tier's quota
before spilling to the next. If yours does, set `PI_DELEGATE_MODEL` to the chain
id and read the `served by:` line in each run's header — with a chain,
`requested:` and `served by:` differ by design, and only the second tells you
which model actually answered. Scale your verification to that.

This is also the quota-drain indicator: when `served by:` starts naming a weaker
tier, the tier above it has run out.

## A note on routing subscriptions

Some setups route a consumer subscription through a proxy rather than using a
metered API key. Whether that is permitted is between you and your provider's
terms — this project takes no position, ships no such configuration, and
recommends no particular provider.

What the tool needs is any model `pi --list-models` can see.
