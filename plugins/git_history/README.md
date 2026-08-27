# Git History

Git History adds a repository tab that traces commits back to the Syrus work that produced them. It connects Git commits to jobs, epics, chats, issues, cron tasks, and landing activity so operators can answer why a commit exists and which automation path created it.

This plugin is useful for auditability and debugging confusing branch history. It reads local bare clones maintained by Syrus and presents the history in the app without changing repository behavior.

## What It Adds

- A repository page tab for commit history.
- Commit attribution to Syrus jobs, epics, chats, schedules, and PRs.
- API endpoints used by the repository Git History UI.

## When To Enable

Enable Git History when operators need provenance for commits produced or handled by Syrus. It is especially useful on busy instances with merge trains, bundles, rebases, and external PR ingestion.

## Operational Notes

The plugin reads local repository clones. In distributed deployments, ensure the process serving the UI can access the needed clone data or has a relay path to a worker that can.
