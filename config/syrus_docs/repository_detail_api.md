# Repository detail API

The app repository detail API keeps shared metadata separate from data used by
individual tabs and cards. `GET /api/v1/app/repositories/:id` returns shared
repository metadata, navigation, actions, counts, and paths. Clients fetch
section data from `/jobs?page=N`, `/health_history`, `/delivery`, and
`/syrus_yml`; the overview-sized cognitive-debt rollup is available from
`/cognitive_debt?view=summary`.

The base endpoint accepts a comma-separated `include` parameter for clients
that deliberately want a combined response. Repository events invalidate the
repository list plus the affected repository's detail, Jobs, health, and
delivery queries, without invalidating unrelated forms, memberships, coverage,
configuration, or cognitive-debt queries.

Counts are cached briefly per repository and viewer and expired by repository
commands. Successful `.syrus.yml` reads are cached by resolved default-branch
revision. If revision resolution is unavailable, the failure summary uses a
short cache scoped to the repository, branch, and viewer so credential-specific
errors cannot cross user boundaries.

Repository command endpoints return only a confirmation message, except for
commands that patch a small, named part of the detail cache. Member, team-grant,
final-approver, and document mutations likewise return the changed row or its
deleted ID rather than re-rendering their lists. Repository documents are
paginated.

Readiness badges can request `/readiness?view=summary`. Active execution probes
are polled independently through `/readiness_probe`, with conditional requests,
so repeated status checks do not resend the static report or command-output
tails when nothing changed.
