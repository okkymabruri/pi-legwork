# pi-legwork

This repository owns the `pi-delegate` CLI, host integration snippets, and the
project-local Damage-Control extension. It is a case study and reference
implementation, not the installed Pi harness. Harness routing and runtime
maintenance belong in `../pi-harness/`; reviewed shared skills belong in
`../workflow-orchestration/`.

## Change paths

- CLI behavior and profiles: `pi-delegate.sh`, then `README.md` and
  `docs/ARCHITECTURE.md`.
- Guard behavior: `extensions/damage-control.ts`,
  `damage-control-rules.json`, and the table test.
- Host integration text: edit its source under `integrations/`; generated blocks
  in consumer files are derivatives.
- Delegation guidance: `skills/pi-delegate/` and `PHILOSOPHY.md`.

Keep local, readonly, research, and full profiles distinct. `local` includes
bash and can mutate; `readonly` enforces a tool-level no-bash boundary;
`research` has network tools without bash/write; `full` is deliberate opt-in.
The guard is a policy hook inside Pi, not a sandbox, and subprocess access can
bypass tool hooks. Keep the extension project-local rather than ambient.

Measurement claims name the apparatus, model/profile, meter, sample size, and
quality result. Do not generalize a token ratio across providers or call it an
efficiency gain when one wallet is outside the meter. Treat concurrency as
profile- and request-shape-specific: local read-heavy results do not establish a
safe research fan-out.

Protect credentials and confidential client material from reads and delegated
prompts. Use synthetic fixtures for guard tests. Verify behavior with:

```bash
node --experimental-strip-types extensions/damage-control.test.ts
./install.sh --check
```

A passing check establishes only those tested boundaries. Preserve unrelated
dirty changes and do not register global extensions as part of repository work.
