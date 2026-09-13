---
description: Install the pi-delegate command, the guard rules, and pick a delegate model
---

Set up pi-legwork on this machine. The plugin ships the skill; this command
installs the parts a skill cannot — a binary on `PATH` and the guard rules.

Work through these in order and stop at the first one that cannot be satisfied,
reporting what is missing rather than continuing past it.

## 1. Check pi

```bash
command -v pi && pi --version
```

If `pi` is missing, stop and tell the user to install it from
https://github.com/badlogic/pi-mono — nothing else can be checked until then.

## 2. Install the command

```bash
mkdir -p ~/.local/bin
install -m755 "${CLAUDE_PLUGIN_ROOT}/pi-delegate.sh" ~/.local/bin/pi-delegate
command -v pi-delegate || echo "~/.local/bin is not on PATH"
```

If `~/.local/bin` is not on `PATH`, tell the user the line to add to their shell
profile rather than editing the profile yourself.

## 3. Install the project-local guard

```bash
"${CLAUDE_PLUGIN_ROOT}/install.sh"
```

This creates `${CLAUDE_PLUGIN_ROOT}/.pi/extensions/damage-control.ts`, removes
legacy global links that point into this checkout, and verifies the tests. Do
not install the extension or rules under `~/.pi`: the guard is intentionally
scoped to pi-legwork. `pi-delegate` loads this trusted extension explicitly so
delegation from another working directory is still protected.

State plainly what it is: a policy hook inside pi's process that blocks
credential-path reads and destructive bash patterns. It is **not** a sandbox —
upstream pi has no permission system. Do not describe it as one.

## 4. Pick a delegate model

```bash
pi --list-models
```

Show the user the list and ask which model to use as the delegate. What matters:
a large context window, terse answers, and quota they are not otherwise spending
— the saving comes from the asymmetry between an expensive caller and a cheap
delegate.

Then give them the export line for their shell profile:

```bash
export PI_DELEGATE_MODEL='<their choice>'
```

Optionally a stronger model for second opinions, which is worth it because a
weak model's confident agreement is worse than no answer:

```bash
export PI_DELEGATE_SO_MODEL='<a stronger model>'
```

## 5. Verify

```bash
pi-delegate --doctor
```

Report the output. Every `FAIL` line says what to do next — work through them and
re-run until it prints `Ready.`

## 6. Confirm it runs

```bash
pi-delegate "Reply with exactly: OK"
```

A successful run prints a header with `served by:` and the answer. Point out that
`served by:` is the model that actually answered, which differs from `requested:`
when a fallback chain is configured — verification effort should scale to it.
