# Codex Agent

Codex Agent connects Syrus workflows and chats to Codex. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.

Enable this plugin when a Syrus instance should offer Codex-backed automation. It is independent from the Claude plugin, so operators can run either provider or both.

## What It Adds

- A workflow agent provider for Codex-backed jobs.
- A chat provider for Codex-backed chat turns.
- Provider health and transient-failure evidence used by admission control and retry logic.

## When To Enable

Enable this plugin when Codex credentials are available and Codex should be selectable for chats or workflows. Disable it when operators want to prevent dispatching any work to Codex.

## Operational Notes

Codex provider health can change independently of plugin state. Syrus uses runtime evidence to avoid failing closed on false quota signals and to resume work when successful Codex evidence appears.
