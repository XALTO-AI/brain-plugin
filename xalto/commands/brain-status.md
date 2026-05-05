---
name: brain-status
description: Check workspace server connection and authentication status
---

Check the workspace server status:

1. Call the workspace MCP server to verify the connection is active
2. Report the server status, version, and uptime from the /health endpoint
3. If the MCP connection requires authentication, Claude Code will handle the OAuth flow automatically
