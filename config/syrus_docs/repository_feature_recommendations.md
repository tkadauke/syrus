# Repository Feature Recommendations

Repository detail payloads include `recommended_actions`, a short ordered list
of setup and automation suggestions for the connected repository. The list is
built by `App::RepositoryFeatureRecommendations.for(repository:, user:)` and is
limited to three entries so the page stays operational rather than becoming an
onboarding checklist.

Each entry has a stable `id`, concise `title` and `body`, `tone`, `category`,
`dismissal_key`, `secondary_path`, and a `cta` object. The frontend stores
dismissed `dismissal_key` values in `localStorage` per repository. Dismissal is
only a local presentation preference; if a recommendation becomes applicable
again under a later version key, the backend can return it again.

CTAs use one of three kinds:

- `job` posts to
  `/api/v1/app/repositories/:repository_id/recommendations/:recommendation_id`.
  The server revalidates that the recommendation is still applicable and
  creates a direct Job with a server-owned title and prompt. The client never
  supplies arbitrary prompt text for these buttons.
- `toggle` posts to the same endpoint and applies a narrow, server-owned
  repository setting change, then returns the normal repository detail payload.
- `link` navigates to an existing focused settings or setup page.

Authorization follows existing Syrus tiers. Recommendation Jobs require
write-tier repository access or a global admin. Repository setting toggles
require repository-admin access, matching the normal repository update policy.

Initial recommendations cover visual review, preview seed data, explicit
Syrus prepare commands, GitHub Actions CI, main branch health and repair,
auto-merge review, PR cost footer, external PR ingestion, scheduled coverage
maintenance, fork auto-sync, and delivery-track configuration. Eligibility is
intentionally conservative and relies on existing repository columns,
scheduled-task rows, recent preview state, and the repository's `.syrus.yml`/
default-branch file list.

`.syrus.yml` and the file list are fetched over the GitHub API
(`GithubClient#file_content_at` / `#file_tree_at`), not from the repository's
local bare clone (`RepositoryBareClone`). This page is served from the web
tier, which doesn't mount the worker's on-disk bare clone (see "Deploy
target" in the top-level agent guide), so a bare-clone read here would always
see "no config" and every "already configured" check (visual review, preview
seed notes, pinned prepare commands, an existing CI workflow, configured
delivery tracks) would keep recommending a feature the repo already uses.
Reading through GitHub instead works regardless of which pod serves the
request — the same reasoning `RepoVisualReviewPlan`/`RepoGradeLoopPlan`/etc.
already apply when resolving a repo's config ahead of a Job dispatch.
