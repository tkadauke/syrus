import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { DEMO_USER, signIn, signInAsDemo } from "./support/auth"

test("dashboard shows the seeded epic", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/dashboard/epics")

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
  await expect(page.getByText("Preview the operator workflow")).toBeVisible()
})

// Extends the smoke check above with the three Dashboard sub-views (epics,
// jobs, workflows -- each its own route), the readiness panel, and the Jobs
// bulk-action affordances, all against the seeded demo/syrus-preview fixture
// data from db/seeds.rb. Multiple page loads per test -- same headroom
// convention as job-lifecycle.spec.ts and epic-management.spec.ts.
test.slow()

test("switches between the epics, jobs, and workflows dashboard sub-views", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/dashboard/epics")
  await expect(page.getByRole("link", { name: "Preview the operator workflow" })).toBeVisible()

  // The "Jobs" sub-view hides closed/approved/running jobs behind the
  // default "Inbox" preset filter (see job-lifecycle.spec.ts); removing it
  // is what makes every seeded Job -- regardless of state -- show up here.
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await page.getByRole("button", { name: "Remove Preset filter" }).click()
  await expect(page.getByRole("link", { name: "Inspect preview dashboard states", exact: true })).toBeVisible()
  await expect(page.getByRole("link", { name: "Document preview seed guidance", exact: true })).toBeVisible()

  // The "Workflows" sub-view has no such default preset (it isn't a job
  // subject), so the seeded Workflow/Step/Run chains from db/seeds.rb show
  // up directly -- one per seeded Job title in the "Job" column.
  await page.goto("/dashboard/workflows")
  await expect(page.getByRole("link", { name: "Inspect preview dashboard states", exact: true }).first()).toBeVisible()
  await expect(page.getByRole("link", { name: "Repair seeded background workflow", exact: true }).first()).toBeVisible()
})

test("shows the system readiness panel for a user who has not finished setup", async ({ page }) => {
  // The demo user's own onboarding is deliberately marked complete by
  // `e2e:seed` (its Epic is force-landed) so its own dashboard renders
  // cleanly for the other specs -- which means its readiness always reads
  // "ok" and never shows this panel. Exercise it with a freshly created,
  // fully isolated user instead: one who has started an onboarding chat
  // (past the /onboarding redirect gate, see App.tsx) but has no landed
  // Epic and no credentials configured, so setup genuinely isn't finished.
  const { email, password } = createReadinessFixtureUser()

  await signIn(page, { email, password })
  await page.goto("/dashboard/jobs")

  // No bin/jobs worker process runs against this preview server, so the
  // Worker/queue readiness check fails reliably regardless of what other
  // E2E specs mutate elsewhere (e.g. onboarding.spec.ts registering a
  // GitHub App, which would otherwise flip the GitHub check to "ok").
  const panel = page.getByRole("region", { name: "System readiness" })
  await expect(panel.getByRole("heading", { name: "System readiness needs attention" })).toBeVisible()
  await expect(panel.getByRole("heading", { name: "Worker/queue" })).toBeVisible()
  await expect(panel.getByText("No Solid Queue worker processes are registered.")).toBeVisible()

  await panel.getByRole("link", { name: "Open settings" }).click()
  await expect(page).toHaveURL(/\/credentials/)
})

test("retries a failed job in bulk from the dashboard and reflects it in the dashboard", async ({ page }) => {
  const title = `E2E bulk retry ${Date.now()}`
  createFailedFixtureJob(title)

  await signInAsDemo(page)
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await page.getByRole("button", { name: "Remove Preset filter" }).click()

  const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) })
  await expect(row).toContainText("failed")

  await row.getByRole("checkbox", { name: `Select ${title}` }).check()
  await expect(page.getByText("1 selected")).toBeVisible()

  await page.getByRole("button", { name: "Retry", exact: true }).click()

  await expect(page.getByText("Retry enqueued for 1 job.")).toBeVisible()
  await expect(row).toContainText("running")
})

// Creates a brand-new user who has started (but not finished) onboarding:
// an onboarding chat exists (past the App.tsx redirect gate) but no Epic has
// landed and no credentials are configured, so the dashboard's readiness
// panel has genuine failing checks to show.
function createReadinessFixtureUser(): { email: string; password: string } {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The dashboard readiness E2E fixture can only be created against the local test database.")
  }

  const email = `e2e-readiness-${Date.now()}@syrus.local`
  const password = "password"

  execFileSync("bin/rails", ["runner", readinessFixtureUserScript(email, password)], {
    env: process.env,
    stdio: "inherit"
  })

  return { email, password }
}

function readinessFixtureUserScript(email: string, password: string): string {
  return `
    user = User.new(email_address: ${JSON.stringify(email)})
    user.assign_attributes(
      name: "E2E Readiness",
      first_name: "E2E",
      last_name: "Readiness",
      global_role: "admin",
      agent_provider: "codex",
      chat_provider: "codex"
    )
    user.password = ${JSON.stringify(password)}
    user.save!

    ChatSession.create!(
      user: user,
      title: "Onboarding",
      mode: "planning",
      pinned: true,
      last_message_at: Time.current,
      onboarding: true
    )
  `
}

// Creates a standalone failed Job with a real failed Workflow/Step/Run chain
// (mirroring db/seeds.rb's "Repair seeded background workflow" fixture) so
// the bulk-retry test has a deterministic, uniquely-titled target instead of
// reaching for a seeded Job another spec file might be mutating concurrently
// (job-lifecycle.spec.ts already retries/approves/cancels the seeded ones).
function createFailedFixtureJob(title: string) {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The dashboard bulk-retry E2E fixture can only be created against the local test database.")
  }

  execFileSync("bin/rails", ["runner", failedFixtureJobScript(title)], {
    env: process.env,
    stdio: "inherit"
  })
}

function failedFixtureJobScript(title: string): string {
  return `
    user = User.find_by!(email_address: ${JSON.stringify(DEMO_USER.email)})
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")

    job = Job.create!(
      repository: repository,
      kind: "direct",
      issue_title: ${JSON.stringify(title)},
      issue_body: "E2E fixture: a failed job for the dashboard bulk-retry test.",
      user: user,
      owner_user: user,
      state: "failed",
      agent_provider: "codex",
      credential_mode: "pat",
      priority: "medium",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending"
    )

    workflow = Workflow.create!(
      job: job,
      user: user,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "failed",
      started_at: 10.minutes.ago,
      finished_at: 5.minutes.ago,
      failure_reason: "grader_failed"
    )

    prepare_step = Step.create!(workflow: workflow, kind: "prepare", position: 0, iteration: 1, state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
    implement_step = Step.create!(workflow: workflow, kind: "implement", position: 1, iteration: 1, state: "failed", started_at: 8.minutes.ago, finished_at: 5.minutes.ago)
    prepare_step.update!(next_step_id: implement_step.id)

    Run.create!(job: job, user: user, step: prepare_step, trigger_kind: "initial", agent_provider: "codex", state: "succeeded", iteration: 1, started_at: prepare_step.started_at, finished_at: prepare_step.finished_at)
    Run.create!(job: job, user: user, step: implement_step, trigger_kind: "initial", agent_provider: "codex", state: "failed", iteration: 1, started_at: implement_step.started_at, finished_at: implement_step.finished_at, prompt: "E2E fixture retry target.")
  `
}
