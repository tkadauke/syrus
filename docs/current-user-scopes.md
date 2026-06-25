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
  - app/controllers/api/v1/app/chat_whiteboards_controller.rb
  - app/controllers/api/v1/app/chats_controller.rb
  - app/controllers/api/v1/app/credentials_controller.rb
  - app/controllers/api/v1/app/credentials/documents_controller.rb
  - app/controllers/api/v1/app/cron_templates_controller.rb
  - app/controllers/api/v1/app/dashboard_controller.rb
  - app/controllers/api/v1/app/direct_jobs_controller.rb
  - app/controllers/api/v1/app/epics_controller.rb
  - app/controllers/api/v1/app/filters_controller.rb
  - app/controllers/api/v1/app/insights/spending_controller.rb
  - app/controllers/api/v1/app/profiles_controller.rb
  - app/controllers/api/v1/app/job_attachments_controller.rb
  - app/controllers/api/v1/app/job_claims_controller.rb
  - app/controllers/api/v1/app/job_lifecycle_controller.rb
  - app/controllers/api/v1/app/job_metadata_controller.rb
  - app/controllers/api/v1/app/job_pins_controller.rb
  - app/controllers/api/v1/app/job_run_commands_controller.rb
  - app/controllers/api/v1/app/jobs_controller.rb
  - app/controllers/api/v1/app/layout_version_controller.rb
  - app/controllers/api/v1/app/memories_controller.rb
  - app/controllers/api/v1/app/notifications_controller.rb
  - app/controllers/api/v1/app/repositories_controller.rb
  - app/controllers/api/v1/app/repository_documents_controller.rb
  - app/controllers/api/v1/app/scheduled_tasks_controller.rb
  - app/controllers/api/v1/app/setup_controller.rb
  - app/controllers/api/v1/app/smart_folders_controller.rb
  - app/controllers/api/v1/app/tags_controller.rb
  - app/controllers/api/v1/app/theme_controller.rb
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
  - app/controllers/admin/github_app_controller.rb
  - app/controllers/application_controller.rb
  - app/controllers/api/v1/app/auth_controller.rb
  - app/controllers/api/v1/app/admin/console_controller.rb
  - app/controllers/api/v1/app/admin/github_app_controller.rb
  - app/controllers/api/v1/app/admin/installations_controller.rb
  - app/controllers/api/v1/app/admin/invitations_controller.rb
  - app/controllers/api/v1/app/admin/queue_controller.rb
  - app/controllers/api/v1/app/admin/spawned_processes_controller.rb
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
`ScheduledTask.where(user: Current.user)` instead of broader model scopes.

| File | Classification | Reason |
| --- | --- | --- |
| `app/controllers/application_controller.rb` | per-user/private and admin gate | System alerts and default chat navigation are computed for the signed-in user. `require_admin` is the shared admin guard. |
| `app/controllers/spa_controller.rb` | per-user/private and admin gate | Serves the SPA shell only after checking ownership for private chat routes; admin shell routes use the shared admin guard. |
| `app/views/spa/show.html.erb` | per-user/private | Renders the SPA bootstrap payload for the current browser session. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Reports the current browser session, redirects already signed-in users to their app shell, signs out the current user, resumes the session for public auth status, and serializes public auth state, including invitation-aware account creation affordances and the current user when present. |
| `app/controllers/api/v1/app/bootstrap_controller.rb` | per-user/private | Serializes the signed-in user, app settings visible to that user, CSRF token, and default chat path. |
| `app/controllers/api/v1/app/auth_controller.rb` | per-user/private | Returns app-session identity for the current browser user. |
| `app/controllers/api/v1/app/bug_reports_controller.rb` | per-user/private | Files bug reports with the current user as reporter/context. |
| `app/controllers/api/v1/app/chat_whiteboards_controller.rb` | per-user/private | Locates whiteboards through `Current.user.chat_sessions`. |
| `app/controllers/api/v1/app/chats_controller.rb` | per-user/private | Chat sessions, proposals, attached repositories/jobs/documents/epics, and pending actions are all owned or selected through the current user's associations. |
| `app/controllers/api/v1/app/credentials/documents_controller.rb` | per-user/private | Personal credential documents are listed, created, and deleted through `Current.user.documents`. |
| `app/controllers/api/v1/app/cron_templates_controller.rb` | per-user/private | Cron templates and selectable repositories are scoped to the current user. |
| `app/controllers/api/v1/app/dashboard_controller.rb` | per-user/private | Dashboard payload, preferences, bulk job actions, tags, approvals, and broadcasts operate on `Current.user` jobs/epics/tags. |
| `app/controllers/api/v1/app/direct_jobs_controller.rb` | per-user/private | Direct jobs can only be created in active repositories owned by the current user, using that user's configured agent providers. |
| `app/controllers/api/v1/app/epics_controller.rb` | per-user/private | Epic create/update/read paths use `Current.user.epics`; repository choices come from the same user. |
| `app/controllers/api/v1/app/filters_controller.rb` | per-user/private | Foreign-key filter options resolve against user-owned repositories, epics, jobs, and tags. Hostnames are a cross-system option but only labels, not user data. |
| `app/controllers/api/v1/app/insights/spending_controller.rb` | per-user/private | Spending rollups are computed for the signed-in user unless the viewer is an admin, in which case the payload intentionally expands to instance-wide totals. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Profile reads and writes serialize or mutate the signed-in user's profile details. Team profile payloads omit credentials while using the current user for access context, profile-directory visibility, and owner-label visibility for another operator's recent jobs. |
| `app/controllers/api/v1/app/job_attachments_controller.rb` | per-user/private | Job attachment changes first find the job via `Current.user.jobs` and broadcast back to that user. |
| `app/controllers/api/v1/app/job_claims_controller.rb` | per-user/private | Job claim and release actions find jobs through `Current.user.jobs` and broadcast ownership updates back to that user. |
| `app/controllers/api/v1/app/job_lifecycle_controller.rb` | per-user/private | Retry, approval, cancellation, close, and broadcasts operate on jobs found through `Current.user.jobs`. |
| `app/controllers/api/v1/app/job_metadata_controller.rb` | per-user/private and admin gate | Tags and dependency targets are user-scoped. Dependency override is separately admin-only. |
| `app/controllers/api/v1/app/job_pins_controller.rb` | per-user/private | Pins are per-user rows on jobs found through `Current.user.jobs`. |
| `app/controllers/api/v1/app/job_run_commands_controller.rb` | per-user/private | Run commands target jobs found through `Current.user.jobs` and validate agent providers against the current user. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Team profile payloads expose public profile/work summaries through the current user's app session. |
| `app/controllers/api/v1/app/jobs_controller.rb` | per-user/private and admin gate | Job detail/source use `Current.user.jobs`; timeline is separately admin-only because it exposes run history. |
| `app/controllers/api/v1/app/layout_version_controller.rb` | per-user/private | Updates only `Current.user.layout_version` for the signed-in operator. |
| `app/controllers/api/v1/app/memories_controller.rb` | per-user/private and admin gate | Memory listing includes the current user's own memories plus repository-published memories for that user's repositories; writes are owner-only unless the viewer is an admin. |
| `app/controllers/api/v1/app/notifications_controller.rb` | per-user/private | Notification listing and mark-read commands operate only on `Current.user.notifications`. |
| `app/controllers/api/v1/app/profiles_controller.rb` | team-visible with current-user context | Team profiles include credential-safe user summaries visible to signed-in users; `Current.user` decides whether owner labels and current-user-specific details should be shown. |
| `app/controllers/api/v1/app/profiles_controller.rb` | per-user/private | Reads and updates the signed-in user's profile fields and public profile settings, and compares requested profiles to `Current.user` before exposing current-user-specific details. |
| `app/controllers/api/v1/app/repositories_controller.rb` | per-user/private and admin affordance | Repository CRUD and GitHub issue actions use `Current.user.repositories` and the current user's GitHub credential. The GitHub App register path is only exposed to admins. |
| `app/controllers/api/v1/app/repository_documents_controller.rb` | per-user/private | Repository documents are attached to repositories owned by the current user and found through that user's repository ids. |
| `app/controllers/api/v1/app/scheduled_tasks_controller.rb` | per-user/private | Scheduled tasks are created from current-user repositories/templates and listed/found with `where(user: Current.user)`. |
| `app/controllers/api/v1/app/setup_controller.rb` | per-user/private | Setup readiness, completion state, credentials, credential checks, repositories, onboarding state, first-run progress, and provider configuration are computed for the signed-in user so onboarding reflects that user's state. |
| `app/controllers/api/v1/app/smart_folders_controller.rb` | per-user/private | User-defined smart folders are owned by `Current.user`; built-ins are returned through `SmartFolder.for_user`. |
| `app/controllers/api/v1/app/tags_controller.rb` | per-user/private | Tags are created, updated, deleted, and listed through `Current.user.tags`. |
| `app/controllers/api/v1/app/theme_controller.rb` | per-user/private | Updates only `Current.user.theme` for the signed-in operator. |
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
| `app/controllers/admin/github_app_controller.rb` | admin-only | Legacy GitHub App manifest callback queues installation sync for the current admin after `Admin::BaseController` gates access. |
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
