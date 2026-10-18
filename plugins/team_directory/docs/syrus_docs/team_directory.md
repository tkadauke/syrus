# Team Directory

The `team_directory` plugin provides a read-only directory of people using a
Syrus instance. It is enabled by default and can be toggled in **Admin →
Plugins**.

## What operators can see

The Team page at `/profiles` shows safe profile summaries and counts for each
operator. `/profiles/:id` shows one person's profile plus bounded lists of
their active repositories, non-archived epics, jobs, and recent activity.
The payload excludes email addresses, credentials, agent-provider settings,
and other private user configuration.

Every page and API endpoint requires an authenticated operator. The directory
does not grant access to linked work and does not alter core team
authorization; it is only a view over records the instance already has.

## Single-operator instances

With fewer than two users, the Team sidebar item is hidden. Direct routes and
the authenticated API remain available, and `/profiles` displays a
single-user explanation. This keeps local installations uncluttered without
making the feature behave like missing data or an authorization failure.

## Routes

- `GET /api/v1/app/profiles` — profile summaries and aggregate work counts.
- `GET /api/v1/app/profiles/:id` — one profile and bounded recent work.
- `/profiles` — the Team directory.
- `/profiles/:id` — an operator profile.

## Enable and disable semantics

Disabling `team_directory` removes its sidebar and frontend contributions and
makes its plugin API routes unavailable through the standard plugin gate. It
does not remove users or change authorization, jobs, epics, or repositories.
Re-enabling the plugin reconstructs the views from those existing core
records; the plugin owns no directory data that needs restoration.
