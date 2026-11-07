# GitHub Permission Sync

GitHub permission sync detects drift in both directions: Syrus users with
write/admin repository access but insufficient GitHub access, and GitHub
write/admin collaborators who have no corresponding Syrus access. The sync is
detect-only; it does not grant or revoke access automatically.

Findings use reason codes including `no_github_handle`,
`not_a_github_collaborator`, and `insufficient_github_permission`. They appear
on the Repository edit page for operator resolution. Read-tier GitHub
collaborators are intentionally not surfaced because they do not imply Syrus
write access.

The sync service, scheduled job, persistence, and UI component are documented
in [GitHub permission-sync architecture](../../docs/engineering/architecture/github-permission-sync.md).
