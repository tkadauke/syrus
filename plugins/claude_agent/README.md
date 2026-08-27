# Claude Agent

Claude Agent connects Syrus workflows and chats to the Claude CLI/provider adapter. It handles agent invocation, transcript capture, provider availability evidence, and the same workflow-side MCP tool surface used by implementation, review, repair, and chat turns.

Enable this plugin when a Syrus instance should offer Claude-backed automation. It can run alongside other agent-provider plugins so jobs and chats choose the appropriate provider per workflow.

## What It Adds

- A workflow agent provider for Claude-backed jobs.
- A chat provider for Claude-backed chat turns.
- Provider availability evidence and failure classification integration.

## When To Enable

Enable this plugin if the host has a configured Claude account or API path and operators want Claude as an available agent. Disable it when the instance should never dispatch work to Claude.

## Operational Notes

Provider availability is tracked separately from plugin enablement. A plugin can be enabled while the provider is temporarily out of usage, degraded, or unavailable.
