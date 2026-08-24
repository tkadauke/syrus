# GitHub Permission Sync

Warns about drift between Syrus repository role tiers and real GitHub
collaborator permissions. Detection and surfacing only — this never
enforces or auto-corrects anything on either side. Part of EPIC-257:
groundwork for a future where self-hosted git removes GitHub as a required
central host, at which point GitHub can no longer be assumed to be the
source of truth for commit access.

## What runs

`GithubPermissionSyncer#sync` (sibling to `GithubAppInstallationSyncer`) is
invoked by `SyncGithubPermissionsJob`, scheduled in `config/recurring.yml`
every 30 minutes on the `polling` queue. It no-ops when no GitHub App is
registered (`AppSetting.github_app_registered?`).

For every non-archived `Repository` with an active GitHub App
`Installation` (`Repository#app_credential_active?`), it fetches
collaborator permissions via `GithubClient#collaborator_permissions` (GitHub's
five-tier `permissions` hash collapsed to `read`/`write`/`admin`, matching
`RepositoryMembership::ROLES`) and checks both directions. A per-repository
GitHub API failure is logged and skipped; it does not stop the sync from
covering the rest of the repositories.

## Direction 1 — Syrus write/admin, no matching GitHub access

The dangerous direction: Syrus would let someone approve, retry, or cancel
Jobs, or manage repository settings, without matching commit rights on
GitHub.

Every direct `RepositoryMembership` row at `write` or `admin` tier is
checked against the GitHub collaborator list, matched by
`User#github_handle` (case-insensitive). Only direct membership rows are
checked — a `write`/`admin` tier granted purely through a `Team` has no
per-user row to store the flag on.

The result is written onto the membership row as
`github_permission_mismatch_reason` (`nil` when everything lines up) plus
`github_permission_mismatch_checked_at`:

- `no_github_handle` — the user has no `github_handle` on file, so GitHub
  access can't be verified.
- `not_a_github_collaborator` — the user has a handle, but it isn't a
  collaborator on the repository at all.
- `insufficient_github_permission` — the user is a collaborator, but their
  GitHub permission tier is below their Syrus tier (e.g. GitHub `read`
  against Syrus `write`).

## Direction 2 — GitHub write/admin, no Syrus access at all

A GitHub collaborator with `write` or `admin` permission whose
`github_handle` doesn't resolve to a Syrus user with any access on the
repository (`Repository#effective_role_for` — direct membership or
team-inherited) gets a `GithubCollaboratorDiscrepancy` row: `github_login`,
`github_permission`, `checked_at`. Read-tier collaborators are not
surfaced — a plain read-only GitHub account isn't a meaningful gap. Rows
that are no longer mismatched (collaborator removed, downgraded below
write, or a Syrus user with access now exists) are pruned on the next sync.

## UI

Both signals surface on the repository's **Members** tab
(`GET /api/v1/app/repositories/:id/memberships`, rendered by
`RepositoryMembersRoute`): a per-row "GitHub mismatch" warning badge for
direction 1, and a separate "GitHub-only collaborators" list for direction
2. Both are read-only displays; there is no action to take from this tab
beyond what the existing membership/team-grant controls already offer.
