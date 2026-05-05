# Brain Plugin

Thin Claude Code plugin that connects to a Brain workspace-server.

## Install

From the marketplace:

```
/plugin marketplace add XALTO-AI/brain-plugin
/plugin install xalto@xalto
```

## Configuration

Set `BRAIN_SERVER_URL` if the server is not at `https://127.0.0.1:7443`:

```bash
export BRAIN_SERVER_URL="https://brain.your-org.example"
```

## Files

- `.claude-plugin/plugin.json` — plugin manifest
- `.mcp.json` — MCP transport (HTTP to the server's `/mcp` endpoint)
- `hooks/session-start.sh` — health check + agent-facing onboarding instruction
- `commands/brain-status.md` — `/brain-status` slash command

See the repository root [README](../README.md) for the full install + auth walkthrough.
