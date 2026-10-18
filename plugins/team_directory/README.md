# Team Directory

Team Directory is the bundled, read-only people directory for a multi-user
Syrus instance. It adds a Team sidebar entry at `/profiles` and profile pages
at `/profiles/:id`, summarising each operator's recent jobs, epics, and active
repositories from records Syrus already owns.

## Visibility and authorization

The directory is available to signed-in operators; its app API returns `401`
to signed-out requests. It exposes profile fields and safe work summaries, but
not email addresses, credentials, provider settings, or other private user
configuration. It is informational only and does not grant access to linked
work or replace Syrus's core team authorization.

On a single-operator instance the sidebar entry is hidden because there is no
team to browse. The authenticated API and direct profile routes remain valid,
and the directory page explains the single-user state instead of treating it
as an error.

## Routes

- `GET /api/v1/app/profiles` lists safe profile summaries and work counts.
- `GET /api/v1/app/profiles/:id` returns one profile with bounded recent work.
- `/profiles` and `/profiles/:id` render the directory and profile pages.

## Enabling and disabling

The plugin is enabled by default and can be disabled from Admin → Plugins.
Disabling it removes the sidebar contribution, frontend registration, and
plugin API availability; core users, jobs, epics, repositories, and their
authorization are unchanged. Re-enabling it restores the read-only views from
those existing records without a data migration.
