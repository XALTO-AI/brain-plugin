# Xalto Brain — Claude Code Plugin

Thin-client [Claude Code](https://claude.com/claude-code) plugin that connects an interactive session to a Brain workspace-server. Provides MCP tools for memory, entity, and team context, plus a session-start hook that auto-loads the user's profile.

This repository is the public Claude Code marketplace for Xalto plugins. The server itself lives in `XALTO-AI/Brain` (private) and is hosted by your organization — typically a Mac Mini behind a reverse proxy at a dedicated URL.

## Install

```
/plugin marketplace add XALTO-AI/brain-plugin
/plugin install xalto@xalto
/mcp                                  # Google OAuth flow against your Brain server
```

After installation, MCP tools are available as `mcp__plugin_xalto_brain__*` (e.g. `connection_status`, `memory_search`, `entity_get`, …).

## Configuration

| Env var             | Default                           | What it does                                              |
|---------------------|-----------------------------------|-----------------------------------------------------------|
| `BRAIN_SERVER_URL`  | `https://127.0.0.1:7443`          | Base URL of the workspace-server. Set this to your org's Brain URL. |

Set the env var before launching Claude Code if your Brain server isn't running locally:

```bash
export BRAIN_SERVER_URL="https://brain.your-org.example"
claude
```

For Claude Desktop and other MCP clients that reject self-signed certs, point this at a URL with a trusted certificate (e.g. your org's reverse proxy).

## What's in this repo

```
.claude-plugin/marketplace.json   # registry manifest
xalto/                            # the plugin (MCP server-key remains "brain")
  .claude-plugin/plugin.json
  .mcp.json                       # MCP transport config
  hooks/                          # session-start hook
  commands/                       # /brain-status slash command
  README.md
```

The plugin is intentionally thin: ~70 lines of bash + JSON + markdown. All real logic lives server-side.

## Auth

Authentication is handled by Claude Code's MCP OAuth 2.1 flow. On first `/mcp` against the server, your browser opens for Google consent, the server validates your domain via Google Workspace, and Claude Code persists the access token. No tokens or shared secrets are baked into the plugin.

Only Google Workspace users in domains your Brain server has been configured to allow can authenticate. The plugin itself does no access control — that lives in the server.

## License

MIT — see [LICENSE](LICENSE).
