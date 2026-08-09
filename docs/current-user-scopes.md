# Current.user Scope Audit

Audited for epic #780. The app has no team membership model today, so most
`Current.user` scoping is either per-user/private or admin-only. Team-visible
scope is limited to cross-user profile metadata until there is a first-class
team scope to replace the current per-user associations.

No broad scope removal was made as part of this audit. Existing `Current.user`
relations remain in place because they are the replacement semantics that keep
private user data separated.

```yaml current_user_scope_files
per-user/private:
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/bootstrap_controller.rb
  - app/controllers/api/v1/app/bug_reports_controller.rb
  - app/controllers/api/v1/app/report_issue_controller.rb
  - app/controllers/api/v1/app/chat_job_status_controller.rb
  - app/controllers/api/v1/app/chat_whiteboards_controller.rb
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
  - app/controllers/api/v1/app/repositories_controller.rb
  - app/controllers/api/v1/app/repository_documents_controller.rb
  - app/controllers/api/v1/app/repository_flaky_tests_controller.rb
  - app/controllers/api/v1/app/scheduled_tasks_controller.rb
  - app/controllers/api/v1/app/search_controller.rb
  - app/controllers/api/v1/app/setup_controller.rb
  - app/controllers/api/v1/app/smart_folders_controller.rb
  - app/controllers/api/v1/app/speech_to_text_controller.rb
  - app/controllers/api/v1/app/tags_controller.rb
  - app/controllers/api/v1/app/terminal_sessions_controller.rb
  - app/controllers/api/v1/app/theme_controller.rb
  - app/controllers/api/v1/app/tours_controller.rb
  - app/controllers/api/v1/app/video_walkthroughs_controller.rb
  - app/controllers/api/v1/app/whiteboard_snapshots_controller.rb
  - app/controllers/api/v1/app/workflows_controller.rb
  - app/controllers/application_controller.rb
  - app/controllers/spa_controller.rb
  - app/views/spa/show.html.erb
team-visible:
  - app/controllers/api/v1/app/profiles_controller.rb
public/session:
  - app/controllers/concerns/authentication.rb
  - app/controllers/api/v1/app/auth_controller.rb
admin-only:
  - app/controllers/admin/base_controller.rb
  - app/controllers/application_controller.rb
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/admin/console_controller.rb
  - app/controllers/api/v1/app/admin/github_app_controller.rb
  - app/controllers/api/v1/app/admin/installations_controller.rb
  - app/controllers/api/v1/app/admin/invitations_controller.rb
  - app/controllers/api/v1/app/admin/queue_controller.rb
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
| `app/controllers/api/v1/app/report_issue_controller.rb` | per-user/private | Files GitHub issues with the current user's connected GitHub token. |
| `app/controllers/api/v1/app/chat_job_status_controller.rb` | per-user/private | Returns job and epic status for confirmed proposals in a chat session found through `Current.user.chat_sessions`. |
| `app/controllers/api/v1/app/chat_whiteboards_controller.rb` | per-user/private | Locates whiteboards through `Current.user.chat_sessions`. |
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
| `app/controllers/api/v1/app/epics_controller.rb` | per-user/private | Epic create/update/read paths use `Current.user.epics`; repository choices come from the same user. |
| `app/controllers/api/v1/app/filters_controller.rb` | per-user/private | Foreign-key filter options resolve against user-owned repositories, epics, jobs, and tags. Hostnames are a cross-system option but only labels, not user data. |
| `app/controllers/api/v1/app/insights/spending_controller.rb` | per-user/private | Spending rollups are computed for the signed-in user unless the viewer is an admin, in which case the payload intentionally expands to instance-wide totals. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Profile reads and writes serialize or mutate the signed-in user's profile details. Team profile payloads omit credentials while using the current user for access context, profile-directory visibility, and owner-label visibility for another operator's recent jobs. |
| `app/controllers/api/v1/app/job_attachments_controller.rb` | per-user/private | Job attachment changes first find the job via `Current.user.jobs` and broadcast back to that user. |
| `app/controllers/api/v1/app/job_claims_controller.rb` | per-user/private | Job claim and release actions find jobs through `Current.user.jobs` and broadcast ownership updates back to that user. |
| `app/controllers/api/v1/app/job_coding_mode_controller.rb` | per-user/private | Opens or reuses a coding-mode ChatSession linked to a Job found through `Current.user.jobs`, and initialises the Job branch checkout inside that user's chat workspace. |
| `app/controllers/api/v1/app/job_lifecycle_controller.rb` | per-user/private | Retry, approval, cancellation, close, and broadcasts operate on jobs found through `Current.user.jobs`. |
| `app/controllers/api/v1/app/local_daemon_sessions_controller.rb` | per-user/private | Daemon tunnel sessions are created, read, and destroyed through `Current.user.chat_sessions`; auth tokens belong to the current user. |
| `app/controllers/api/v1/app/job_metadata_controller.rb` | per-user/private and admin gate | Tags and dependency targets are user-scoped. Dependency override is separately admin-only. |
| `app/controllers/api/v1/app/job_pins_controller.rb` | per-user/private | Pins are per-user rows on jobs found through `Current.user.jobs`. |
| `app/controllers/api/v1/app/job_run_commands_controller.rb` | per-user/private | Run commands target jobs found through `Current.user.jobs` and validate agent providers against the current user. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Team profile payloads expose public profile/work summaries through the current user's app session. |
| `app/controllers/api/v1/app/jobs_controller.rb` | per-user/private and admin gate | Job detail/source and chat feedback submission use `Current.user.jobs`; timeline is separately admin-only because it exposes run history. |
| `app/controllers/api/v1/app/local_daemon_sessions_controller.rb` | per-user/private | Creates and manages local daemon sessions through `Current.user.chat_sessions`; daemon session creation sets `user: Current.user`. |
| `app/controllers/api/v1/app/memories_controller.rb` | per-user/private and admin gate | Memory listing includes the current user's own memories plus repository-published memories for that user's repositories; writes are owner-only unless the viewer is an admin. |
| `app/controllers/api/v1/app/notification_preferences_controller.rb` | per-user/private | Reads and updates only `Current.user.notification_preferences`. |
| `app/controllers/api/v1/app/pending_feedback_controller.rb` | per-user/private | Pending feedback actions (apply/ignore/replace) find the parent job through `Current.user.jobs` and serialize a full `App::JobDetailPayload` for that user. |
| `app/controllers/api/v1/app/notifications_controller.rb` | per-user/private | Notification listing and mark-read commands operate only on `Current.user.notifications`. |
| `app/controllers/api/v1/app/passkeys_controller.rb` | per-user/private | Passkey registration options and credential verification use `Current.user` to scope the challenge and passkey rows to the authenticated user. |
| `app/controllers/api/v1/app/profiles_controller.rb` | team-visible with current-user context | Team profiles include credential-safe user summaries visible to signed-in users; `Current.user` decides whether owner labels and current-user-specific details should be shown. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Reads and updates the signed-in user's profile fields and public profile settings, and compares requested profiles to `Current.user` before exposing current-user-specific details. |
| `app/controllers/api/v1/app/input_sources_controller.rb` | per-user/private | Registry-backed input source CRUD finds the parent repository through `Current.user.repositories` and resolves source types only from `PluginRegistry.providers_for(:input_source)`, so only the repository owner can read or update source credentials. |
| `app/controllers/api/v1/app/repositories_controller.rb` | per-user/private and admin affordance | Repository CRUD and GitHub issue actions use `Current.user.repositories` and the current user's GitHub credential. The GitHub App register path is only exposed to admins. |
| `app/controllers/api/v1/app/repository_documents_controller.rb` | per-user/private | Repository documents are attached to repositories owned by the current user and found through that user's repository ids. |
| `app/controllers/api/v1/app/repository_flaky_tests_controller.rb` | per-user/private | Flaky test summaries are fetched through `Current.user.repositories` so only the repository owner can read them. |
| `app/controllers/api/v1/app/scheduled_tasks_controller.rb` | per-user/private | Scheduled tasks are created from current-user repositories/templates and listed/found with `where(user: Current.user)`. |
| `app/controllers/api/v1/app/search_controller.rb` | per-user/private | Unified search queries user-scoped FTS rows and hydrates Jobs, Epics, and chat messages back through current-user ownership checks before returning results. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup readiness, completion state, credentials, credential checks, repositories, onboarding state, first-run progress, and provider configuration are computed for the signed-in user so onboarding reflects that user's state. |
| `app/controllers/api/v1/app/smart_folders_controller.rb` | per-user/private | User-defined smart folders are owned by `Current.user`; built-ins are returned through `SmartFolder.for_user`. |
| `app/controllers/api/v1/app/speech_to_text_controller.rb` | per-user/private | Speech-to-text endpoint access is gated through `Current.user.chat_sessions` so backend transcription requests stay scoped to the current user's chats. |
| `app/controllers/api/v1/app/tags_controller.rb` | per-user/private | Tags are created, updated, deleted, and listed through `Current.user.tags`. |
| `app/controllers/api/v1/app/terminal_sessions_controller.rb` | per-user/private | Terminal sessions are listed, created, shown, and killed through `Current.user.terminal_sessions`; recent Workflow workspace choices and workflow defaults are scoped through `Current.user.workflows`. |
| `app/controllers/api/v1/app/theme_controller.rb` | per-user/private | Updates only `Current.user.theme` for the signed-in operator. |
| `app/controllers/api/v1/app/tours_controller.rb` | per-user/private | Marks individual tours seen and resets all seen tours through `Current.user.mark_tour_seen` / `Current.user.reset_tours!`. |
| `app/controllers/api/v1/app/video_walkthroughs_controller.rb` | per-user/private | Creates walkthroughs through `Current.user.chat_sessions`; retry joins chat_sessions on `Current.user.id`. |
| `app/controllers/api/v1/app/whiteboard_snapshots_controller.rb` | per-user/private | Lists and loads snapshots only through `Current.user.chat_sessions`. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Public auth status can resume the current session and serialize whether a signed-in user is present. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Profile browsing excludes private credential data while using the current user for viewer-sensitive profile payloads. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup status is computed for the signed-in user's credentials, repositories, and first-run progress. |

## Team-visible

Team profiles are visible to signed-in users so operators can see who owns
work. There is still no team ownership table, membership table, or team-scoped
repository relation in the current data model. GitHub repositories may be
organization repositories, but most Syrus access here is still mediated through
the signed-in user's repository rows and GitHub credential, so those paths
remain classified as per-user/private.

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
| `app/controllers/api/v1/app/admin/console_controller.rb` | admin-only | Builds console payloads with the current admin as actor. |
| `app/controllers/api/v1/app/admin/github_app_controller.rb` | admin-only | Builds GitHub App manifests using the current admin's identity/contact context. |
| `app/controllers/api/v1/app/admin/installations_controller.rb` | admin-only | Queues installation sync for the current admin. |
| `app/controllers/api/v1/app/admin/invitations_controller.rb` | admin-only | Records the current admin as invitation creator. |
| `app/controllers/api/v1/app/admin/queue_controller.rb` | admin-only | Reads queue/process state through admin-only payloads and user-aware filters. |
| `app/controllers/api/v1/app/admin/spawned_processes_controller.rb` | admin-only | Lists and kills subprocesses through admin payloads, with the current admin passed for authorization/audit. |
| `app/controllers/api/v1/app/admin/users_controller.rb` | admin-only | Lists user records through an admin payload with the current admin as actor. |
| `app/controllers/api/v1/app/auth_controller.rb` | admin-only | Public auth status includes current-user context when a signed-in admin hits auth routes. |
| `app/controllers/api/v1/app/credentials_controller.rb` | per-user/private and admin-only | Normal credential reads/writes mutate only the current user's credentials. API token rotation and revocation are admin-only because API bearer access exposes admin endpoints. |
| `app/controllers/api/v1/app/profiles_controller.rb` | team-visible with self-aware badges | Team profiles are deliberately visible across users, while ownership labels compare profile rows to the signed-in user. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup status is computed for the current operator's credentials, repositories, and first job progress. |
