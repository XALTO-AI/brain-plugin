---
description: Inspect and manage the Brain audit-chain validator daemon
---

Run `brain-validator $ARGUMENTS` and show the output. If no $ARGUMENTS provided, run `brain-validator status`.

Common subcommands:
- `status` — daemon health + last-pull info
- `restart` — restart the daemon
- `tripwires` — list any active tripwires from local mirror
- `update` — force a self-update poll
- `wipe` — DESTRUCTIVE: remove the device key. Re-register to recover.
