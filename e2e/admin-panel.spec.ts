import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { NON_ADMIN_USER, signIn, signInAsDemo } from "./support/auth"

test.slow()

type AdminPanelFixture = {
  processCommand: string
  processHost: string
  queueClass: string
  stuckKind: string
  stuckRunLabel: string
}

test("admin renders queue, stuck jobs, plugin registry, and process inventory", async ({ page }) => {
  skipWhenRemote()
  const fixture = createAdminPanelFixtures()

  await signInAsDemo(page)

  await openAdminNav(page, "Queue")
  await expect(page.getByRole("heading", { name: "Queue" })).toBeVisible()
  await expect(page.getByRole("navigation", { name: "Queue tabs" }).getByRole("link", { name: "Active" })).toBeVisible()
  await expect(page.getByRole("navigation", { name: "Admin queue smart folders" })).toBeVisible()
  await expect(page.getByRole("row").filter({ hasText: fixture.queueClass })).toContainText("runs")

  await openAdminNav(page, "Stuck")
  await expect(page.getByRole("heading", { name: "Stuck Things" })).toBeVisible()
  const refreshStuck = page.getByRole("button", { name: "Refresh" })
  await expect(refreshStuck).toBeEnabled()
  await refreshStuck.click()
  const stuckRow = page.getByRole("row")
    .filter({ hasText: fixture.stuckRunLabel })
    .filter({ hasText: fixture.stuckKind })
  await expect(stuckRow).toContainText("Operator needed")
  await expect(stuckRow).toContainText(fixture.stuckKind)
  await expect(stuckRow).toContainText("without enough evidence of a live worker")

  await openAdminNav(page, "Plugins")
  await expect(page.getByRole("heading", { name: "Plugins" })).toBeVisible()
  const registry = page.getByRole("region", { name: "Registered plugins" })
  await expect(registry.getByRole("heading", { name: "Design Docs" })).toBeVisible()
  await expect(pluginCard(page, "Design Docs")).toContainText("Enabled")
  await expect(pluginCard(page, "Agent Insights")).toContainText("Disabled")

  await openAdminNav(page, "Processes")
  await expect(page.getByRole("heading", { name: "Processes" })).toBeVisible()
  const processRow = page.getByRole("row").filter({ hasText: fixture.processCommand })
  await expect(processRow).toContainText("agent")
  await expect(processRow).toContainText(fixture.processHost)
  await expect(processRow).toContainText("running")
})

test("admin surfaces are hidden and inaccessible for a non-admin user", async ({ page }) => {
  await signIn(page, NON_ADMIN_USER)

  await page.getByRole("button", { name: NON_ADMIN_USER.email }).click()
  await expect(page.getByRole("link", { name: "Admin", exact: true })).toHaveCount(0)

  for (const path of ["/admin/queue", "/admin/stuck", "/admin/plugins", "/admin/processes"]) {
    await page.goto(path)
    await expect(page.getByText("Admin access required.")).toBeVisible()
    await expect(page.getByRole("navigation", { name: "Admin" })).toHaveCount(0)
  }
})

async function openAdminNav(page: Page, name: "Queue" | "Stuck" | "Plugins" | "Processes") {
  await page.goto("/admin")
  await page.getByRole("navigation", { name: "Admin" }).getByRole("link", { name, exact: true }).click()
}

function pluginCard(page: Page, heading: string) {
  return page.locator("article").filter({ has: page.getByRole("heading", { name: heading, exact: true }) })
}

function skipWhenRemote() {
  test.skip(!!process.env.E2E_BASE_URL, "Admin panel E2E creates local preview fixture data.")
}

function createAdminPanelFixtures(): AdminPanelFixture {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The admin panel E2E fixtures can only be created against the local test database.")
  }

  const suffix = Date.now()
  const fixture = {
    processCommand: `codex exec e2e-admin-panel-${suffix}`,
    processHost: `e2e-admin-worker-${suffix}`,
    queueClass: `E2EAdminPanelJob${suffix}`,
    stuckDetail: `E2E stale run fixture ${suffix}`,
    stuckKind: "running_run_without_live_worker_evidence"
  }

  const output = execFileSync("bin/rails", ["runner", adminPanelFixtureScript(fixture)], {
    encoding: "utf8",
    env: {
      ...process.env,
      BUNDLE_PATH: `${process.cwd()}/vendor/bundle`,
      BUNDLE_APP_CONFIG: `${process.cwd()}/.bundle`
    },
    stdio: ["ignore", "pipe", "inherit"]
  })
  const metadata = JSON.parse(output.trim().split(/\r?\n/).at(-1) || "{}") as { stuckRunId: number }

  return { ...fixture, stuckRunLabel: `Run #${metadata.stuckRunId}` }
}

function adminPanelFixtureScript(fixture: Omit<AdminPanelFixture, "stuckRunLabel"> & { stuckDetail: string }): string {
  return `
    user = User.find_by!(email_address: "demo@syrus.local")
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")

    process = SolidQueue::Process.create!(
      kind: "Worker",
      name: "e2e-admin-worker-${Date.now()}",
      hostname: ${JSON.stringify(fixture.processHost)},
      pid: 4242,
      last_heartbeat_at: Time.current,
      created_at: Time.current,
      metadata: { "queues" => "runs", "thread_pool_size" => 1 }
    )
    job = SolidQueue::Job.create!(
      class_name: ${JSON.stringify(fixture.queueClass)},
      queue_name: "runs",
      priority: 0,
      arguments: { "arguments" => [ "e2e-admin-panel" ] },
      created_at: Time.current,
      updated_at: Time.current
    )
    SolidQueue::ClaimedExecution.create!(job: job, process: process, created_at: Time.current)

    stale_job = Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "direct",
      issue_title: ${JSON.stringify(fixture.stuckDetail)},
      issue_body: "Created by e2e/admin-panel.spec.ts",
      priority: "medium",
      agent_provider: "codex",
      credential_mode: "app"
    )
    stale_job.advance_after_triage! if stale_job.may_advance_after_triage?
    stale_run = stale_job.runs.first
    raise "expected stale fixture run" unless stale_run

    stale_workflow = stale_run.step.workflow
    stale_step = stale_run.step
    stale_time = 10.minutes.ago
    stale_job.update_columns(state: "running", started_at: stale_time, updated_at: stale_time)
    stale_workflow.update_columns(state: "running", started_at: stale_time, updated_at: stale_time)
    stale_step.update_columns(state: "running", started_at: stale_time, updated_at: stale_time)
    stale_run.update_columns(state: "running", started_at: stale_time, last_heartbeat_at: stale_time, updated_at: stale_time)

    SpawnedProcess.create!(
      kind: "agent",
      command: ${JSON.stringify(fixture.processCommand)},
      hostname: ${JSON.stringify(fixture.processHost)},
      pid: 4243,
      started_at: 2.minutes.ago,
      last_chunk_at: Time.current
    )

    PluginRecord.find_by!(name: "design_docs").update!(enabled: true)
    PluginRecord.find_by!(name: "agent_insights").update!(enabled: false)

    puts JSON.generate({ stuckRunId: stale_run.id })
  `
}
