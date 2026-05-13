# Release Notes

## Unreleased

- Agents can now call the `ask_operator(question:, context:)` MCP tool
  when a materially design-affecting ambiguity requires human input.
  Repository operator-chat settings decide whether the question is sent
  inside Syrus, through Telegram, or rejected with a clear disabled
  error.
