# GitHub Source

GitHub Source is Syrus' built-in GitHub integration. It polls issues and pull requests, opens and updates PRs, reads check state, performs landing operations, and supplies the source-control primitives other workflows rely on.

For most Syrus installations this is core infrastructure and is not disableable. Future source plugins can follow the same extension points, but GitHub remains the default path for issue-to-PR automation.

## What It Adds

- GitHub issue and pull request ingestion.
- PR creation, update, merge, rebase, and check-state operations.
- Source-control provider behavior used by landing, merge trains, and CI repair.

## When To Enable

This plugin is enabled by default and required for GitHub-backed Syrus repositories. It should only be replaced if another source-control provider fully covers the same workflow surface.

## Operational Notes

Syrus polls GitHub rather than relying on inbound webhooks. Repository credentials and polling settings determine what gets ingested and how PR operations are authenticated.
