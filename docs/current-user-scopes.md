# Current.user Scope Audit

Audited for epic #780. Most `Current.user` scoping is per-user/private or
admin-only; see [Teams](#teams) for the first-class team scope EPIC-257 added
(`Team`/`TeamMembership`/`TeamRepository`), which now additively widens
repository access alongside direct `RepositoryMembership` rows.

No broad scope removal was made as part of this audit. Existing `Current.user`
relations remain in place because they are the replacement semantics that keep
private user data separated.

## Policy layer (Repository/Job/Epic)

EPIC-257 (global roles, repository role tiers, teams, and GitHub permission
parity) replaces this convention-based, per-controller scoping with policy
objects one resource at a time. The first step introduced the `pundit` gem
and `RepositoryPolicy`, `JobPolicy`, and `EpicPolicy` under `app/policies/`,
wrapping the access rules documented in this file for
`Api::V1::App::RepositoriesController`, `Api::V1::App::JobsController`, and
`Api::V1::App::EpicsController`. A follow-up step then expanded
`RepositoryMembership::ROLES` from `owner`/`collaborator` to `read`/`write`/
`admin` tiers and wired those tiers into the write-capability predicates the
first step had deliberately left as stubs (see below).

- `RepositoryPolicy::Scope#resolve` returns repositories where the user
  holds an `admin`-tier `RepositoryMembership` — the tier every repository's
  FK owner is seeded with on creation (`Repository#seed_owner_membership`),
  so this is behavior-preserving for existing owners and additive for anyone
  later promoted to `admin`. It replaced the original `Current.user.repositories`
  FK-only scope.
- `JobPolicy::Scope#resolve` is `Job.accessible_to(user)` (repository
  membership OR team-granted access, any tier, including upstream
  repositories — mirrors `Epic.accessible_to`; see `app/models/job.rb`).
  This closed the visibility gap where two `RepositoryMembership` holders on
  the same repository could already see each other's Epics but not each
  other's Jobs.
- `EpicPolicy::Scope#resolve` is exactly `Epic.accessible_to(user)`
  (repository membership OR team-granted access, any tier, including
  upstream repositories — see `Epic.accessible_to` in `app/models/epic.rb`).

`RepositoryPolicy#write?`/`#admin?` and `JobPolicy#write?` are the tier
predicates:

- `RepositoryPolicy#admin?` is `admin`-tier `RepositoryMembership` OR global
  admin (`ApplicationPolicy#admin?`, folded in via `super`). It gates
  `Api::V1::App::RepositoriesController#update` (the repository
  settings/credentials form) — previously owner-FK-only — and backs
  `RepositoryPolicy::Scope` above, so every `find_repository`-based action in
  that controller is now admin-tier gated the same way the FK owner always
  was. It also scopes the new `Api::V1::App::RepositoryMembershipsController`
  (list/add/change-role/remove members) end to end via its own
  `find_repository`.
- `RepositoryPolicy#write?` is `write`-tier-or-higher `RepositoryMembership`
  OR global admin. Defined for parity/future use; no controller calls it yet
  (repository-level actions are currently all-or-nothing at admin tier).
- `JobPolicy#write?` (replacing the old, narrower `JobPolicy#update?`) is the
  job's creator, a global admin, OR a `write`-tier-or-higher
  `RepositoryMembership` on the job's repository
  (`record.repository.member_at_least?(user, "write")`). This is the "later
  repo-role-tiers job" flagged by the earlier revision of this doc: it widens
  `chat_feedback`/`update_priority`/`update_provider_setting`
  (`Api::V1::App::JobsController`) and `approve`/`run_again`
  ("Retry")/`cancel` (`Api::V1::App::JobLifecycleController`) from
  creator-or-admin-only to creator-or-admin-or-write-tier-member.
  `Api::V1::App::BaseController#authorize_job_mutation!` is the one shared
  gate both controllers call after resolving the target Job through the
  widened, repository-membership-based `JobPolicy::Scope` (so a
  visible-but-not-writable Job 403s there instead of 404ing at the finder).
  `JobLifecycleController`'s other actions (`start`, `restart`, `force_fail`,
  `reopen`, `pause`, `unpause`, `open_in_local_mode`, `cancel_local_mode`) and
  every other `Current.user.jobs`-scoped controller were left untouched —
  they were never widened, so they need no new guard.

`RepositoryMembership::ROLES` is ordered low to high (`read`, `write`,
`admin`); `RepositoryMembership#at_least?(tier)` and the `.at_least(tier)`
scope compare by that rank, so an `admin`-tier row satisfies a `write`-tier
check. `Repository#member_at_least?(user, tier)` /
`Repository#membership_for(user)` are the model-level lookups the policies
and `Repository#effective_agent_provider` (now `write`-tier-or-higher only —
a `read`-tier member can no longer override the agent provider a Job runs
with) share.
`Api::V1::App::EpicsController#membership_on_repo?` (the re-parenting guard
when `PATCH /epics/:id` changes `repository_id`) was similarly promoted from
"any membership row" to `write`-tier-or-higher.

The pre-tier migration mapped existing `owner` rows to `admin` and
`collaborator` rows to the more conservative `read` (not `write`) — see
`db/migrate/20260823212331_expand_repository_membership_role_tiers.rb`.
`collaborator` never granted Job mutation rights before this Job, only
narrow Epic visibility plus the `membership_on_repo?`/agent-provider
overrides, so silently upgrading it to `write` would have been a real
privilege escalation on upgrade.

None of the three `Scope` classes bypass for global admins at the Scope
level. `find_repository`, `find_job_by_param`, and `find_epic` call
`policy_scope(Repository)` / `policy_scope(Job)` / `policy_scope(Epic)`
instead of the raw association, so a record outside the Scope still 404s;
admin bypass lives on the per-record predicates (`#show?`, `#write?`,
`#admin?`) that call sites invoke explicitly instead.

`EpicPolicy` additionally reproduces the three per-action checks
`EpicsController` already had before this policy layer existed, unchanged:
`unclaim?` (current claimant or admin), `reassign?(via_owner_user_id_param:)`
(admin-only when reassigning through the `owner_user_id` param; the legacy
`owner_id` param path is unrestricted), and `advance_state?(target_state:)`
(product owners cannot advance into `ready`/`in_progress`/`done`). These are
genuine "global admins bypass this policy" rules, unrelated to repository
role tiers, and are preserved as-is.

`ApplicationPolicy#admin?` remains the base global-admin-bypass helper
(`user&.admin?`); `RepositoryPolicy#admin?` and `JobPolicy#write?` both fold
it in (via `super` in `RepositoryPolicy#admin?`, via a direct `admin?` call
in `JobPolicy#write?`) so a global admin always satisfies the tier check
even with no `RepositoryMembership` row of their own.

`spec/docs/current_user_scopes_spec.rb` only scans `app/controllers/**` and
`app/views/**`, so plugin-owned controllers (e.g. `plugins/whiteboard_tools`'s
`ChatWhiteboardsController`/`WhiteboardSnapshotsController`, both scoped
through `Current.user.accessible_chat_sessions`, same as the rest of the
chat surface) aren't covered by this audit or its spec. That's a pre-existing
gap in the audit's scan globs, not something specific to those controllers.

```yaml current_user_scope_files
per-user/private:
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/bootstrap_controller.rb
  - app/controllers/api/v1/app/bug_reports_controller.rb
  - app/controllers/api/v1/app/browser_errors_controller.rb
  - app/controllers/api/v1/app/event_actions_controller.rb
  - app/controllers/api/v1/app/report_issue_controller.rb
  - app/controllers/api/v1/app/chat_job_status_controller.rb
  - app/controllers/api/v1/app/chat_participants_controller.rb
  - app/controllers/api/v1/app/chats_controller.rb
  - app/controllers/concerns/chat_attachable_resolution.rb
  - app/controllers/concerns/chat_attachment_search.rb
  - app/controllers/concerns/chat_index_payload.rb
  - app/controllers/concerns/chat_proposal_outcome.rb
  - app/controllers/concerns/chat_provider_options.rb
  - app/controllers/concerns/chat_serialization.rb
  - app/controllers/concerns/chat_session_lifecycle.rb
  - app/controllers/concerns/chat_search.rb
  - app/controllers/concerns/performance_logging_context.rb
  - app/controllers/api/v1/app/credentials_controller.rb
  - app/controllers/api/v1/app/credentials/documents_controller.rb
  - app/controllers/api/v1/app/cron_templates_controller.rb
  - app/controllers/api/v1/app/dashboard_controller.rb
  - app/controllers/api/v1/app/desktop_tokens_controller.rb
  - app/controllers/api/v1/app/direct_jobs_controller.rb
  - app/controllers/api/v1/app/epics_controller.rb
  - app/controllers/api/v1/app/filters_controller.rb
  - app/controllers/api/v1/app/insight_schedule_configs_controller.rb
  - app/controllers/api/v1/app/insight_suggestions_controller.rb
  - app/controllers/api/v1/app/insights/spending_controller.rb
  - app/controllers/api/v1/app/input_sources_controller.rb
  - app/controllers/api/v1/app/profiles_controller.rb
  - app/controllers/api/v1/app/job_attachments_controller.rb
  - app/controllers/api/v1/app/job_claims_controller.rb
  - app/controllers/api/v1/app/job_coding_mode_controller.rb
  - app/controllers/api/v1/app/job_lifecycle_controller.rb
  - app/controllers/api/v1/app/local_daemon_sessions_controller.rb
  - app/controllers/api/v1/app/job_metadata_controller.rb
  - app/controllers/api/v1/app/job_pins_controller.rb
  - app/controllers/api/v1/app/job_preview_controller.rb
  - app/controllers/api/v1/app/job_run_commands_controller.rb
  - app/controllers/api/v1/app/job_test_results_controller.rb
  - app/controllers/api/v1/app/jobs_controller.rb
  - app/controllers/api/v1/app/local_daemon_sessions_controller.rb
  - app/controllers/api/v1/app/memories_controller.rb
  - app/controllers/api/v1/app/notification_preferences_controller.rb
  - app/controllers/api/v1/app/notifications_controller.rb
  - app/controllers/api/v1/app/passkeys_controller.rb
  - app/controllers/api/v1/app/pending_feedback_controller.rb
  - app/controllers/api/v1/app/platform_identities_controller.rb
  - app/controllers/api/v1/app/repositories_controller.rb
  - app/controllers/api/v1/app/repository_documents_controller.rb
  - app/controllers/api/v1/app/repository_flaky_tests_controller.rb
  - app/controllers/api/v1/app/repository_plugin_tabs_controller.rb
  - app/controllers/api/v1/app/repository_preview_controller.rb
  - app/controllers/api/v1/app/repository_tests_controller.rb
  - app/controllers/concerns/repository_tabs_serialization.rb
  - app/controllers/api/v1/app/scheduled_tasks_controller.rb
  - app/controllers/api/v1/app/search_controller.rb
  - app/controllers/api/v1/app/setup_controller.rb
  - app/controllers/api/v1/app/sidebar_nav_order_controller.rb
  - app/controllers/api/v1/app/skills_controller.rb
  - app/controllers/api/v1/app/smart_folders_controller.rb
  - app/controllers/api/v1/app/speech_to_text_controller.rb
  - app/controllers/api/v1/app/tags_controller.rb
  - app/controllers/api/v1/app/terminal_sessions_controller.rb
  - app/controllers/api/v1/app/theme_controller.rb
  - app/controllers/api/v1/app/tours_controller.rb
  - app/controllers/api/v1/app/users_controller.rb
  - app/controllers/api/v1/app/video_walkthroughs_controller.rb
  - app/controllers/api/v1/app/workflow_warnings_controller.rb
  - app/controllers/api/v1/app/workflows_controller.rb
  - app/controllers/application_controller.rb
  - app/controllers/spa_controller.rb
  - app/views/spa/show.html.erb
team-visible:
  - app/controllers/api/v1/app/profiles_controller.rb
team-tier:
  - app/controllers/api/v1/app/teams_controller.rb
  - app/controllers/api/v1/app/team_memberships_controller.rb
  - app/controllers/concerns/team_serialization.rb
public/session:
  - app/controllers/concerns/authentication.rb
  - app/controllers/api/v1/app/auth_controller.rb
admin-only:
  - app/controllers/admin/base_controller.rb
  - app/controllers/application_controller.rb
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/admin/build_cache_controller.rb
  - app/controllers/api/v1/app/admin/console_controller.rb
  - app/controllers/api/v1/app/admin/github_app_controller.rb
  - app/controllers/api/v1/app/admin/installations_controller.rb
  - app/controllers/api/v1/app/admin/invitations_controller.rb
  - app/controllers/api/v1/app/admin/queue_controller.rb
  - app/controllers/api/v1/app/admin/restart_controller.rb
  - app/controllers/api/v1/app/admin/settings_controller.rb
  - app/controllers/api/v1/app/admin/spawned_processes_controller.rb
  - app/controllers/api/v1/app/admin/supervisor_chats_controller.rb
  - app/controllers/api/v1/app/admin/users_controller.rb
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/base_controller.rb
  - app/controllers/api/v1/app/credentials_controller.rb
  - app/controllers/api/v1/app/job_metadata_controller.rb
  - app/controllers/api/v1/app/jobs_controller.rb
  - app/controllers/api/v1/app/profiles_controller.rb
  - app/controllers/api/v1/app/repositories_controller.rb
  - app/controllers/api/v1/app/setup_controller.rb
```

## Teams

EPIC-257's final step added `Team` (name), `TeamMembership` (user_id,
team_id, role: `member`/`owner`), and `TeamRepository` (team_id,
repository_id, role: `read`/`write`/`admin`) so one repository can be
granted to multiple teams at potentially different tiers — a bulk-grant
mechanism additive to direct `RepositoryMembership` rows, not a replacement
for them.

`Repository#effective_role_for(user)` is the highest of: global admin (via
`User#admin?`) -> `"admin"`; the user's direct `RepositoryMembership#role`;
the best `TeamRepository#role` across teams the user belongs to that have a
grant on that repository. `Repository#member_at_least?(user, tier)` is
implemented in terms of it, so `RepositoryPolicy#write?`/`#admin?` and
`JobPolicy#write?` picked up team-inherited access without any policy-level
changes. A repository with zero `TeamRepository` grants resolves identically
to the direct-membership-only model that preceded teams (see
`spec/models/repository_spec.rb`'s `#effective_role_for` coverage).

`RepositoryPolicy::Scope#resolve`, `Job.accessible_to`, and
`Epic.accessible_to` were widened the same way: `Repository.accessible_repository_ids_for(user)`
now unions direct `RepositoryMembership` repo ids with `TeamRepository`
repo ids (any tier, for `Job`/`Epic` visibility — any grant counts, mirroring
how a single `RepositoryMembership` row of any tier already granted
visibility); `RepositoryPolicy::Scope` unions admin-tier rows from both
sources, since it backs repository settings visibility specifically.

`TeamPolicy` (`app/policies/team_policy.rb`) gates the team CRUD API
itself: `#show?` is any team member or global admin; `#write?` (rename,
delete, membership CRUD) is an owner-tier `TeamMembership` or global admin.
Any authenticated user may create a team (`#create?`) and becomes its first
owner, mirroring `Repository#seed_owner_membership`.

Two authorization surfaces exist for the underlying `TeamRepository` grant
records, matching who initiates the grant:

- `Api::V1::App::TeamsController` / `TeamMembershipsController` — team CRUD
  and roster management, gated by `TeamPolicy` (team owner or global admin).
  The team detail payload includes the team's `TeamRepository` grants
  read-only for visibility, but does not let a team owner add or remove them
  — see below.
- `Api::V1::App::RepositoryTeamGrantsController` — grants/revokes a team's
  access to a specific repository, nested under
  `/repositories/:repository_id/team_grants` and gated identically to
  `RepositoryMembershipsController` (admin-tier `RepositoryPolicy::Scope`).
  This is deliberate: letting a team *owner* grant their team access to an
  arbitrary repository they have no rights on would be a privilege
  escalation, so only a repository admin (or global admin) can create a
  `TeamRepository` row. It shares a `RepositoryMembersSerialization` payload
  concern with `RepositoryMembershipsController` so both mutate the same
  repository "Members" page query cache entry.

The `AdminTeams.tsx` UI (`/admin/teams`) follows `AdminUsers.tsx`'s
list+detail pattern and, like all `/admin/*` SPA routes, is gated
server-side by `SpaController#admin_spa_path?`/`require_admin` — so while the
API itself authorizes team owners, the current in-scope UI surface for team
CRUD is reachable only by global admins. Non-admin team owners can still
manage their team's roster via the same API (e.g. through the Go CLI or a
future non-admin UI). Repository admins manage `TeamRepository` grants from
the existing repository "Members" tab (`RepositoryMembers.tsx`), which now
lists both direct memberships and team grants side by side.

## Per-user/private

These scopes expose or mutate records that belong to the signed-in user.
They intentionally use associations such as `Current.user.jobs`,
`Current.user.repositories`, `Current.user.epics`, `Current.user.tags`,
`Current.user.documents`, `Current.user.chat_sessions`, and
`Current.user.terminal_sessions`, plus `ScheduledTask.where(user: Current.user)`,
instead of broader model scopes.

| File | Classification | Reason |
| --- | --- | --- |
| `app/controllers/application_controller.rb` | per-user/private and admin gate | System alerts and default chat navigation are computed for the signed-in user. `require_admin` is the shared admin guard. |
| `app/controllers/spa_controller.rb` | per-user/private and admin gate | Serves the SPA shell only after checking ownership for private chat routes; admin shell routes use the shared admin guard. |
| `app/views/spa/show.html.erb` | per-user/private | Renders the SPA bootstrap payload for the current browser session. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Reports the current browser session, redirects already signed-in users to their app shell, signs out the current user, resumes the session for public auth status, and serializes public auth state, including invitation-aware account creation affordances and the current user when present. |
| `app/controllers/api/v1/app/bootstrap_controller.rb` | per-user/private | Serializes the signed-in user, app settings visible to that user, CSRF token, and default chat path. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Returns app-session identity for the current browser user. |
| `app/controllers/api/v1/app/bug_reports_controller.rb` | per-user/private | Files bug reports with the current user as reporter/context. |
| `app/controllers/api/v1/app/browser_errors_controller.rb` | per-user/private | Records browser error diagnostics under the signed-in user; admin-only endpoints expose the aggregate event stream. |
| `app/controllers/api/v1/app/event_actions_controller.rb` | per-user/private | Files a Job from an observability event as the signed-in user; the filer authorizes the actor before creating anything. |
| `app/controllers/api/v1/app/report_issue_controller.rb` | per-user/private | Files GitHub issues with the current user's connected GitHub token. |
| `app/controllers/api/v1/app/chat_job_status_controller.rb` | per-user/private | Returns job and epic status for confirmed proposals in a chat session found through `Current.user.chat_sessions`. |
| `app/controllers/api/v1/app/chat_participants_controller.rb` | per-user/private | Group-chat participant add/remove find the chat through `Current.user.accessible_chat_sessions`, so only current participants can manage membership. |
| `app/controllers/api/v1/app/chats_controller.rb` | per-user/private | Chat sessions, proposals, attached repositories/jobs/documents/epics, and pending actions are all owned or selected through the current user's associations. |
| `app/controllers/concerns/chat_attachable_resolution.rb` | per-user/private | Attachable-resolution helpers (extracted from `ChatsController`) resolve a specific repository/job/document/epic through `Current.user`'s associations. |
| `app/controllers/concerns/chat_attachment_search.rb` | per-user/private | Attachment-search helpers (extracted from `ChatsController`) scope candidate repositories/jobs/documents/epics through `Current.user`'s associations. |
| `app/controllers/concerns/chat_index_payload.rb` | per-user/private | Chat index / recent-chats payload builders (extracted from `ChatsController`) list and group the current user's chat sessions through `Current.user.chat_sessions`. |
| `app/controllers/concerns/chat_proposal_outcome.rb` | per-user/private | Proposal-outcome helpers (extracted from `ChatsController`) start a confirmed Epic as `Current.user` and build the confirmation/rejection notices. |
| `app/controllers/concerns/chat_serialization.rb` | per-user/private | Chat JSON serializers (extracted from `ChatsController`) build the chat/message/attachment payloads, reading `Current.user` for unread state and ownership-scoped fields. |
| `app/controllers/concerns/chat_session_lifecycle.rb` | per-user/private | Chat-session lifecycle helpers (extracted from `ChatsController`) create the session as `Current.user` and branch from a source chat. |
| `app/controllers/concerns/chat_provider_options.rb` | per-user/private | Chat-provider picker helpers (extracted from `ChatsController`) build options from `Current.user`'s configured agent providers. |
| `app/controllers/concerns/chat_search.rb` | per-user/private | Chat-search helpers (extracted from `ChatsController`) search and filter `Current.user`'s chats and serialize the results. |
| `app/controllers/concerns/performance_logging_context.rb` | per-user/private | Performance log request diagnostics include the current user's id/admin flag when a signed-in user is available. |
| `app/controllers/api/v1/app/credentials/documents_controller.rb` | per-user/private | Personal credential documents are listed, created, and deleted through `Current.user.documents`. |
| `app/controllers/api/v1/app/admin/settings_controller.rb` | admin-only | App-wide settings are admin-only; `Current.user` stamps the actor for workflow-admission-control audit metadata and `AdminAction` rows. |
| `app/controllers/api/v1/app/cron_templates_controller.rb` | per-user/private | Cron templates and selectable repositories are scoped to the current user. |
| `app/controllers/api/v1/app/dashboard_controller.rb` | per-user/private | Dashboard payload, preferences, bulk job actions, tags, approvals, and broadcasts operate on `Current.user` jobs/epics/tags. |
| `app/controllers/api/v1/app/direct_jobs_controller.rb` | per-user/private | Direct jobs can only be created in active repositories owned by the current user, using that user's configured agent providers. |
| `app/controllers/api/v1/app/epics_controller.rb` | per-user/private | Epic create/update paths use `Current.user.epics`; repository choices come from the same user. Index/find/dependency-target lookups go through `EpicPolicy` (`policy_scope(Epic)`, exactly `Epic.accessible_to(Current.user)` — see [Policy layer](#policy-layer-repositoryjobepic)); unclaim, reassign, and state-advancement checks are `EpicPolicy` predicates. |
| `app/controllers/api/v1/app/filters_controller.rb` | per-user/private | Foreign-key filter options resolve against user-owned repositories, epics, jobs, and tags. Hostnames are a cross-system option but only labels, not user data. |
| `app/controllers/api/v1/app/insights/spending_controller.rb` | per-user/private | Spending rollups are computed for the signed-in user unless the viewer is an admin, in which case the payload intentionally expands to instance-wide totals. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Profile reads and writes serialize or mutate the signed-in user's profile details. Team profile payloads omit credentials while using the current user for access context, profile-directory visibility, and owner-label visibility for another operator's recent jobs. |
| `app/controllers/api/v1/app/job_attachments_controller.rb` | per-user/private | Job attachment changes first find the job via `Current.user.jobs` and broadcast back to that user. |
| `app/controllers/api/v1/app/job_claims_controller.rb` | per-user/private | Job claim and release actions find jobs through `Current.user.jobs` and broadcast ownership updates back to that user. |
| `app/controllers/api/v1/app/job_coding_mode_controller.rb` | per-user/private | Opens or reuses a coding-mode ChatSession linked to a Job found through `Current.user.jobs`, and initialises the Job branch checkout inside that user's chat workspace. |
| `app/controllers/api/v1/app/job_lifecycle_controller.rb` | per-user/private and repository-write affordance | Retry, approval, cancellation, close, and broadcasts operate on jobs found through `Current.user.jobs`, except `approve`/`run_again`/`cancel`, which resolve through `policy_scope(Job)` and `authorize_job_mutation!` (`JobPolicy#write?` — see [Policy layer](#policy-layer-repositoryjobepic)) so a write-tier-or-higher repository member can act on a job it doesn't own. |
| `app/controllers/api/v1/app/local_daemon_sessions_controller.rb` | per-user/private | Daemon tunnel sessions are created, read, and destroyed through `Current.user.chat_sessions`; auth tokens belong to the current user. |
| `app/controllers/api/v1/app/job_metadata_controller.rb` | per-user/private and admin gate | Tags and dependency targets are user-scoped. Dependency override is separately admin-only. |
| `app/controllers/api/v1/app/job_pins_controller.rb` | per-user/private | Pins are per-user rows on jobs found through `Current.user.jobs`. |
| `app/controllers/api/v1/app/job_run_commands_controller.rb` | per-user/private | Run commands target jobs found through `Current.user.jobs` and validate agent providers against the current user. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Team profile payloads expose public profile/work summaries through the current user's app session. |
| `app/controllers/api/v1/app/jobs_controller.rb` | per-user/private and admin gate | Job detail/source and chat feedback submission are scoped through `JobPolicy` (`policy_scope(Job)`, exactly `Current.user.jobs` — see [Policy layer](#policy-layer-repositoryjobepic)); timeline is separately admin-only because it exposes run history. |
| `app/controllers/api/v1/app/local_daemon_sessions_controller.rb` | per-user/private | Creates and manages local daemon sessions through `Current.user.chat_sessions`; daemon session creation sets `user: Current.user`. |
| `app/controllers/api/v1/app/memories_controller.rb` | per-user/private and admin gate | Memory listing includes the current user's own memories plus repository-published memories for that user's repositories; writes are owner-only unless the viewer is an admin. |
| `app/controllers/api/v1/app/notification_preferences_controller.rb` | per-user/private | Reads and updates only `Current.user.notification_preferences`. |
| `app/controllers/api/v1/app/pending_feedback_controller.rb` | per-user/private | Pending feedback actions (apply/ignore/replace) find the parent job through `Current.user.jobs` and serialize a full `App::JobDetailPayload` for that user. |
| `app/controllers/api/v1/app/notifications_controller.rb` | per-user/private | Notification listing and mark-read commands operate only on `Current.user.notifications`. |
| `app/controllers/api/v1/app/passkeys_controller.rb` | per-user/private | Passkey registration options and credential verification use `Current.user` to scope the challenge and passkey rows to the authenticated user. |
| `app/controllers/api/v1/app/platform_identities_controller.rb` | per-user/private | Platform identity listing, unlinking, and linking-token generation are scoped to `Current.user.platform_identities`. |
| `app/controllers/api/v1/app/profiles_controller.rb` | team-visible with current-user context | Team profiles include credential-safe user summaries visible to signed-in users; `Current.user` decides whether owner labels and current-user-specific details should be shown. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Reads and updates the signed-in user's profile fields and public profile settings, and compares requested profiles to `Current.user` before exposing current-user-specific details. |
| `app/controllers/api/v1/app/input_sources_controller.rb` | per-user/private | Registry-backed input source CRUD finds the parent repository through `Current.user.repositories` and resolves source types only from `PluginRegistry.providers_for(:input_source)`, so only the repository owner can read or update source credentials. |
| `app/controllers/api/v1/app/repositories_controller.rb` | admin-tier and admin affordance | Repository CRUD and GitHub issue actions are scoped through `RepositoryPolicy` (`policy_scope(Repository)`, admin-tier `RepositoryMembership` — see [Policy layer](#policy-layer-repositoryjobepic)) and the current user's GitHub credential. The GitHub App register path is only exposed to global admins. |
| `app/controllers/api/v1/app/repository_memberships_controller.rb` | admin-tier | Lists, adds, changes the role of, and removes `RepositoryMembership` rows, scoped through the same admin-tier `RepositoryPolicy::Scope` as `repositories_controller.rb`. Refuses to remove or demote the last `admin`-tier member of a repository. |
| `app/controllers/api/v1/app/repository_team_grants_controller.rb` | admin-tier | Lists, adds, changes the role of, and removes `TeamRepository` grants for a repository, scoped through the same admin-tier `RepositoryPolicy::Scope` as `repository_memberships_controller.rb` — see [Teams](#teams). |
| `app/controllers/api/v1/app/teams_controller.rb` | team-tier | Team CRUD, scoped through `TeamPolicy`/`policy_scope(Team)`: visible to any team member or global admin, mutable by owner-tier `TeamMembership` or global admin. Any authenticated user may create a team. |
| `app/controllers/api/v1/app/team_memberships_controller.rb` | team-tier | Lists, adds, changes the role of, and removes `TeamMembership` rows, gated by `TeamPolicy#write?` (owner-tier or global admin). Refuses to remove or demote the last `owner`-tier member of a team. |
| `app/controllers/api/v1/app/repository_documents_controller.rb` | per-user/private | Repository documents are attached to repositories owned by the current user and found through that user's repository ids. |
| `app/controllers/api/v1/app/repository_flaky_tests_controller.rb` | per-user/private | Flaky test summaries are fetched through `Current.user.repositories` so only the repository owner can read them. |
| `app/controllers/api/v1/app/repository_preview_controller.rb` | per-user/private | Job-less repository preview show/logs/create/destroy find the repository through `Current.user.repositories`, so only the repository owner can start, inspect, or stop it. |
| `app/controllers/api/v1/app/scheduled_tasks_controller.rb` | per-user/private | Scheduled tasks are created from current-user repositories/templates and listed/found with `where(user: Current.user)`. |
| `app/controllers/api/v1/app/search_controller.rb` | per-user/private | Unified search queries user-scoped FTS rows and hydrates Jobs, Epics, and chat messages back through current-user ownership checks before returning results. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup readiness, completion state, credentials, credential checks, repositories, onboarding state, first-run progress, and provider configuration are computed for the signed-in user so onboarding reflects that user's state. |
| `app/controllers/api/v1/app/skills_controller.rb` | per-user/private | The skill picker/launch endpoints find the parent repository through `Current.user.repositories` and create skill Jobs via `SkillJobs::Creator` scoped to `Current.user`, so only the repository owner can list or launch skills. |
| `app/controllers/api/v1/app/smart_folders_controller.rb` | per-user/private | User-defined smart folders are owned by `Current.user`; built-ins are returned through `SmartFolder.for_user`. |
| `app/controllers/api/v1/app/speech_to_text_controller.rb` | per-user/private | Speech-to-text endpoint access is gated through `Current.user.chat_sessions` so backend transcription requests stay scoped to the current user's chats. |
| `app/controllers/api/v1/app/tags_controller.rb` | per-user/private | Tags are created, updated, deleted, and listed through `Current.user.tags`. |
| `app/controllers/api/v1/app/terminal_sessions_controller.rb` | per-user/private | Terminal sessions are listed, created, shown, and killed through `Current.user.terminal_sessions`; recent Workflow workspace choices and workflow defaults are scoped through `Current.user.workflows`. |
| `app/controllers/api/v1/app/theme_controller.rb` | per-user/private | Updates only `Current.user.theme` for the signed-in operator. |
| `app/controllers/api/v1/app/tours_controller.rb` | per-user/private | Marks individual tours seen and resets all seen tours through `Current.user.mark_tour_seen` / `Current.user.reset_tours!`. |
| `app/controllers/api/v1/app/users_controller.rb` | per-user/private | Invite-picker listing excludes the current user and, when scoping to a chat, excludes that chat's existing participants found through `Current.user.accessible_chat_sessions`. No admin gate — Syrus has no team/org scoping, so any authenticated user may see the flat instance user list. |
| `app/controllers/api/v1/app/video_walkthroughs_controller.rb` | per-user/private | Creates walkthroughs through `Current.user.chat_sessions`; retry joins chat_sessions on `Current.user.id`. |
| `app/controllers/api/v1/app/workflow_warnings_controller.rb` | per-user/private | Warnings are found through jobs scoped to `Current.user.jobs`; filing a fix Job creates it as `Current.user`. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Public auth status can resume the current session and serialize whether a signed-in user is present. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Profile browsing excludes private credential data while using the current user for viewer-sensitive profile payloads. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup status is computed for the signed-in user's credentials, repositories, and first-run progress. |

## Team-visible

Team profiles are visible to signed-in users so operators can see who owns
work; that classification predates and is unrelated to the `Team` model
described in [Teams](#teams) above (a naming coincidence: "team profile"
means "the cross-user profile directory," not "a `Team` record"). GitHub
repositories may be organization repositories, but most Syrus access here is
still mediated through the signed-in user's repository rows and GitHub
credential, so those paths remain classified as per-user/private.

`Api::V1::App::TeamsController`, `TeamMembershipsController`, and
`RepositoryTeamGrantsController` are the first controllers actually scoped
through the `Team` model — see [Teams](#teams).

## Public/session

These scopes may be reachable before authentication and only use `Current.user`
as optional session context.

| File | Classification | Reason |
| --- | --- | --- |
| `app/controllers/concerns/authentication.rb` | public/current session | Authentication redirects use `Current.user` after session resume to send incomplete first-run users to onboarding. |
| `app/controllers/api/v1/app/auth_controller.rb` | public/current session | Status returns the current session user when one exists; auth creation paths are otherwise public and session-scoped. |

## Admin-only

These scopes either guard admin routes or pass the current admin into services
for audit attribution, filtering, or privileged execution. They should remain
behind `require_admin` unless a replacement admin authorization layer is added.

| File | Classification | Reason |
| --- | --- | --- |
| `app/controllers/admin/base_controller.rb` | admin-only | Documents that legacy `/admin/*` controllers use `require_admin`. |
| `app/controllers/api/v1/app/auth_controller.rb` | admin-only | Public auth status uses `Current.user` only to report whether the current session is authenticated. |
| `app/controllers/api/v1/app/base_controller.rb` | admin-only guard | Defines the JSON `require_admin` guard used by SPA admin controllers and local admin-only actions. |
| `app/controllers/api/v1/app/admin/build_cache_controller.rb` | admin-only | Stamps the current admin as requester/confirmer on `AdminBuildCacheClearRequest` create/confirm, for audit. |
| `app/controllers/api/v1/app/admin/console_controller.rb` | admin-only | Builds console payloads with the current admin as actor. |
| `app/controllers/api/v1/app/admin/github_app_controller.rb` | admin-only | Builds GitHub App manifests using the current admin's identity/contact context. |
| `app/controllers/api/v1/app/admin/installations_controller.rb` | admin-only | Queues installation sync for the current admin. |
| `app/controllers/api/v1/app/admin/invitations_controller.rb` | admin-only | Records the current admin as invitation creator. |
| `app/controllers/api/v1/app/admin/queue_controller.rb` | admin-only | Reads queue/process state through admin-only payloads and user-aware filters. |
| `app/controllers/api/v1/app/admin/restart_controller.rb` | admin-only | Writes the Rails.cache restart poison-pill and passes the current admin as actor for `AdminAction` audit logging. |
| `app/controllers/api/v1/app/admin/spawned_processes_controller.rb` | admin-only | Lists and kills subprocesses through admin payloads, with the current admin passed for authorization/audit. |
| `app/controllers/api/v1/app/admin/users_controller.rb` | admin-only | Lists user records through an admin payload with the current admin as actor. |
| `app/controllers/api/v1/app/auth_controller.rb` | admin-only | Public auth status includes current-user context when a signed-in admin hits auth routes. |
| `app/controllers/api/v1/app/credentials_controller.rb` | per-user/private and admin-only | Normal credential reads/writes mutate only the current user's credentials. API token rotation and revocation are admin-only because API bearer access exposes admin endpoints. |
| `app/controllers/api/v1/app/profiles_controller.rb` | team-visible with self-aware badges | Team profiles are deliberately visible across users, while ownership labels compare profile rows to the signed-in user. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup status is computed for the current operator's credentials, repositories, and first job progress. |
