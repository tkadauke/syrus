import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { signIn } from "./support/auth"

test.slow()

type LandingQueueFixture = {
  email: string
  password: string
  approvedTitle: string
  landingTitle: string
}

test("shows approved and landing Jobs in the landing queue surfaces", async ({ page }) => {
  const fixture = createLandingQueueFixture()
  await signIn(page, { email: fixture.email, password: fixture.password })

  await openJob(page, fixture.approvedTitle)
  await expect(page.getByText(/In landing queue: position #1/)).toBeVisible()
  await expect(page.getByText(/Auto-merge not enabled for repository/)).toBeVisible()
  await expect(page.getByRole("link", { name: "Enable auto-merge in repository settings" })).toBeVisible()

  await page.goto("/dashboard/jobs?ownership_scope=mine&view=list")
  await page.getByRole("link", { name: "Landing queue" }).click()

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
  await expect(page.getByRole("columnheader", { name: /Sort by Queue/ })).toBeVisible()
  await expect(page.getByRole("columnheader", { name: "Queue status", exact: true })).toBeVisible()

  const approvedRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: fixture.approvedTitle, exact: true }) })
  await expect(approvedRow).toContainText("#1")
  await expect(approvedRow).toContainText("Auto-merge not enabled for repository")

  const landingRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: fixture.landingTitle, exact: true }) })
  await expect(landingRow).toContainText("#2")
  await expect(landingRow).toContainText("landing")
})

test("pauses and resumes landing queue processing from the dashboard", async ({ page }) => {
  const fixture = createLandingQueueFixture()
  await signIn(page, { email: fixture.email, password: fixture.password })

  await page.goto("/dashboard/jobs?ownership_scope=mine&view=list")
  await page.getByRole("link", { name: "Landing queue" }).click()

  await page.getByRole("button", { name: "Pause landing" }).click()
  await expect(page.getByText("Landing paused.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Resume landing" })).toBeVisible()

  await page.getByRole("button", { name: "Resume landing" }).click()
  await expect(page.getByText("Landing resumed.")).toBeVisible()
  await expect(page.getByRole("button", { name: "Pause landing" })).toBeVisible()
})

async function openJob(page: Page, title: string) {
  await page.goto("/dashboard/jobs?ownership_scope=mine&view=list")
  await page.getByRole("button", { name: "Remove Preset filter" }).click()

  const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) })
  await row.getByRole("link", { name: title, exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
}

function createLandingQueueFixture(): LandingQueueFixture {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The landing queue E2E fixture can only be created against the local test database.")
  }

  const token = `${Date.now()}-${Math.random().toString(16).slice(2)}`
  const email = `e2e-landing-${token}@syrus.local`
  const password = "password"
  const approvedTitle = `E2E approved landing queue ${token}`
  const landingTitle = `E2E active landing queue ${token}`

  execFileSync("bin/rails", ["runner", landingQueueFixtureScript({ email, password, approvedTitle, landingTitle, token })], {
    env: process.env,
    stdio: "inherit"
  })

  return { email, password, approvedTitle, landingTitle }
}

function landingQueueFixtureScript({ email, password, approvedTitle, landingTitle, token }: LandingQueueFixture & { token: string }): string {
  return `
    user = User.new(email_address: ${JSON.stringify(email)})
    user.assign_attributes(
      name: "E2E Landing Queue",
      first_name: "E2E",
      last_name: "Landing Queue",
      global_role: "admin",
      agent_provider: "codex",
      chat_provider: "codex",
      landing_paused: false
    )
    user.password = ${JSON.stringify(password)}
    user.save!

    repository = Repository.create!(
      user: user,
      owner: "e2e-landing",
      name: "queue-${token.toLowerCase().replace(/[^a-z0-9-]/g, "-")}",
      default_branch: "main",
      trigger_label: "syrus",
      polling_enabled: false,
      prepare_enabled: true,
      agent_provider: "codex",
      review_policy: "self",
      feedback_policy: "confirm",
      epic_dependency_policy: "linear"
    )

    ChatSession.create!(
      user: user,
      repository: repository,
      title: "Onboarding",
      mode: "planning",
      pinned: true,
      last_message_at: Time.current,
      onboarding: true
    )

    approved = Job.create!(
      repository: repository,
      kind: "direct",
      issue_title: ${JSON.stringify(approvedTitle)},
      issue_body: "E2E fixture: approved Job blocked in the landing queue because auto-merge is disabled.",
      user: user,
      owner_user: user,
      state: "approved",
      pr_number: 101,
      branch_name: "syrus/e2e-approved-${token}",
      approved_at: 10.minutes.ago,
      approved_via: "operator",
      approved_by_user: user,
      agent_provider: "codex",
      credential_mode: "pat",
      priority: "medium",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending",
      auto_merge_enabled: false,
      landing_queue_position: 1,
      landing_queue_entry_position: 1,
      landing_queue_blocked_reason: { key: "auto_merge_not_enabled" },
      landing_queue_entry_key: "job:e2e-approved-${token}",
      landing_queue_blocker_job_ids: [],
      landing_queue_waiting_job_ids: [],
      landing_queue_dependency_edges: [],
      landing_queue_cached_at: Time.current
    )

    landing = Job.create!(
      repository: repository,
      kind: "direct",
      issue_title: ${JSON.stringify(landingTitle)},
      issue_body: "E2E fixture: Job already in the landing state.",
      user: user,
      owner_user: user,
      state: "landing",
      pr_number: 102,
      branch_name: "syrus/e2e-landing-${token}",
      approved_at: 5.minutes.ago,
      approved_via: "operator",
      approved_by_user: user,
      agent_provider: "codex",
      credential_mode: "pat",
      priority: "medium",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending",
      auto_merge_enabled: true,
      landing_queue_position: 2,
      landing_queue_entry_position: 2,
      landing_queue_blocked_reason: nil,
      landing_queue_entry_key: "job:e2e-landing-${token}",
      landing_queue_blocker_job_ids: [],
      landing_queue_waiting_job_ids: [],
      landing_queue_dependency_edges: [],
      landing_queue_cached_at: Time.current
    )

    workflow = Workflow.create!(
      job: landing,
      user: user,
      trigger_kind: "auto_merge",
      agent_provider: "codex",
      state: "running",
      started_at: 2.minutes.ago
    )
    step = Step.create!(workflow: workflow, kind: "auto_merge", position: 0, iteration: 1, state: "running", started_at: 2.minutes.ago)
    Run.create!(job: landing, user: user, step: step, trigger_kind: "auto_merge", agent_provider: "codex", state: "running", iteration: 1, started_at: 2.minutes.ago)

  `
}
