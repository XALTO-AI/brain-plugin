# Xalto Brain — Claude Code Plugin (retired)

**This plugin is retired and no longer distributed.** The marketplace still
resolves, so existing installs keep working, but it now offers no plugins and
this repository ships no code.

Nothing is lost. Everything the plugin did is now done by something better
placed to do it.

## Where each piece went

| The plugin did | Now |
|---|---|
| Provided the `brain` MCP server | Configured by the **Xalto desktop app**, which points your assistant at a local broker that injects a fresh token per request |
| Told the assistant to call `memory_load_profile` at session start | Served by **brain itself**, in the MCP `initialize` response |
| Installed, registered and health-checked the `brain-validator` daemon | Owned by the **Xalto desktop app**, under Connections → Audit-chain validator |
| Bundled six `brain-validator` binaries + a signed `.pkg` download | Ships **inside the desktop app**, code-signed and notarized with it |

## Why it was retired

Two reasons, and the second is the one that mattered.

**It only ever worked for Claude Code.** The session-start directive lived in a
bash hook wired to a Claude-Code-specific lifecycle event. Claude Desktop,
Codex, the Xalto app's own chat, and anything a customer brought connected to
the same brain and got none of it. Moving that text into the MCP `initialize`
response means every conformant client receives it — same instruction,
delivered by the protocol instead of by one vendor's plugin mechanism.

**Device lifecycle does not belong in a chat session.** The hook probed the
validator daemon on *every* session and, on an unhealthy reading, injected
instructions telling the agent to run local binaries and to refuse the user's
actual request until the checks passed. The daemon is per-device state with a
lifetime measured in months; a chat session is per-invocation and may not happen
for days. That put an install/recovery workflow in the path of unrelated work.

Removing the hook (v0.6.2) fixed the symptom. Retiring the plugin removes the
mechanism.

## If you still have it installed

Uninstall it — otherwise you get the `memory_load_profile` directive twice, once
from the stale hook and once from the MCP server:

```
/plugin uninstall xalto@xalto
/plugin marketplace remove XALTO-AI/brain-plugin
```

Then use the Xalto desktop app, which configures the MCP connection for you.

## Why this repo still exists

It is a tombstone, not a deletion. The marketplace URL is baked into every
existing install; removing the repository outright would break `/plugin`
resolution for anyone who has not uninstalled yet, and would delete the history
explaining why any of this was built. Git history holds the full plugin —
including the audit-chain bootstrap, the Ed25519 attestation verifier, and the
TOFU pinning model — at tag `v0.6.2`.

## License

MIT — see [LICENSE](LICENSE).
