# MCP bridge

The MCP bridge lets an external MCP client -- Claude Code on your laptop, for
example -- call the same tools a Syrus chat agent can. It is a transport, not
a separate permission system: the client sees exactly the tools a chat of
yours would offer, every call is evaluated and audited by your permission
rules, and anything that needs your decision becomes a confirmation card.

## Tokens

Create a token under **Account settings → MCP bridge**, or with the user API:

```bash
curl -X POST -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -d name=laptop https://syrus.example.com/api/v1/app/mcp_bridge_tokens
```

The response contains the token's plaintext once; Syrus stores only a digest.
Bridge tokens are separate from your API token: an API token is not accepted
by the bridge, and a bridge token is not accepted by the REST API. Revoking a
bridge token (`DELETE /api/v1/app/mcp_bridge_tokens/:id`, or **Revoke** in
settings) cuts off that one client immediately.

Register the endpoint with Claude Code:

```bash
claude mcp add --transport http syrus https://syrus.example.com/mcp/bridge \
  --header "Authorization: Bearer $SYRUS_MCP_TOKEN"
```

## The bridge chat

Each token acts in its own chat, titled **MCP bridge: <token name>**, created
the first time the token is used. The client's tool calls are attributed to
that chat, and its confirmation cards and authorization requests appear there
for you to confirm or reject. Outcomes are posted to the chat as system
messages; the client reads them with `list_pending_actions` or by calling the
tool again.

Syrus's own chat agent never answers in a bridge chat: the external client is
its agent. Messages you type there are not sent to the client.

## What the client can do

- Essential tools (research, reading Jobs and workflows, context management)
  always run, as they do in chat.
- Gated tools follow your permission rules and presets. A tool that would ask
  in chat asks here, as a card in the bridge chat, and offers the same
  permanent "always allow" choices.
- Admin-only tools are offered only when the token belongs to an admin, as in
  chat.

Tool calls are recorded in MCP tool usage with the `bridge` transport.
