import { test, expect } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { signInAsDemo } from "../../../e2e/support/auth"

// The terminal plugin is off by default -- a terminal session is a real
// shell on the worker, so an operator has to opt in. No worker/PTY runs in
// this preview sandbox (see .syrus.yml's visual_review.seed_notes), so once
// a session is opened the test only asserts on what the UI renders without a
// live PTY: the panel opening with the right chrome, not any real output.
test("signed-in admin enables the Terminal plugin and opens a session panel from a Job's workflow", async ({ page }) => {
  // This spec asserts the plugin's disabled starting state and then enables
  // it, so it leaves the plugin enabled for the next run. Put it back first:
  // plugin enablement is instance-wide and nothing else resets it.
  // Also give the seeded workflow a workspace directory: the "Open terminal
  // in workspace" action hides itself when the workspace is not present on
  // this storage root (Terminal::WorkspaceAvailability), and nothing in a
  // preview database ever creates one.
  execFileSync("bin/rails", ["runner", `
    PluginRecord.find_or_initialize_by(name: "terminal").update!(enabled: false)

    workflow = Job.find_by!(issue_title: "Inspect preview dashboard states").workflows.order(:id).last
    workflow.update_columns(cleaned_up_at: nil, worker_storage_key: nil, worker_hostname: nil)
    FileUtils.mkdir_p(WorkflowWorkspace.path_for(workflow))
  `], { env: process.env, stdio: "inherit" })

  await signInAsDemo(page)

  await page.goto("/dashboard")
  const primaryNav = page.getByRole("navigation", { name: "Primary" })
  await expect(primaryNav.getByRole("link", { name: "Terminal" })).toHaveCount(0)

  // Toggle from the plugin's own page: its card in the list carries a link to
  // here in its heading, and enabling re-renders the list under the cursor,
  // so the click lands on that link often enough to matter.
  await page.goto("/admin/plugins/terminal")
  // The page renders its own h1 and the plugin's docs render another.
  await expect(page.getByRole("heading", { name: "Terminal", level: 1 }).first()).toBeVisible()
  await expect(page.getByRole("button", { name: "Enable", exact: true })).toBeVisible()
  await page.getByRole("button", { name: "Enable", exact: true }).click()

  // Enabling reloads the SPA -- a plugin's sidebar page and ui_slot only
  // resolve on a fresh boot -- and a cold dev-mode render of this app can
  // take the better part of a minute.
  await page.waitForLoadState("load")
  await expect(page.getByRole("button", { name: "Disable", exact: true })).toBeVisible({ timeout: 60_000 })

  await page.goto("/dashboard")

  await expect(primaryNav.getByRole("link", { name: "Terminal" })).toBeVisible()

  // "Inspect preview dashboard states" is the one seeded demo Job with a full
  // Workflow/Step/Run chain (see db/seeds.rb), so its Workflows tab has a
  // workflow card to open a terminal session against.
  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await page.getByRole("link", { name: "Inspect preview dashboard states" }).click()
  await expect(page).toHaveURL(/\/jobs\/\d+$/)

  await page.getByRole("button", { name: "Workflows", exact: false }).click()
  await page.getByRole("button", { name: "Open terminal in workspace" }).click()
  await expect(page).toHaveURL(/\/terminal\?session=\d+$/)

  // The session panel opens against a real session record, but nothing ever
  // streams into it here -- assert the pane's chrome, not any PTY output.
  await expect(page.getByRole("tab", { selected: true })).toHaveText(/^WF-\d+ workspace$/)
  await expect(page.getByText(/\.syrus\/workflows\/\d+$/)).toBeVisible()
  await expect(page.getByRole("button", { name: "Kill" })).toBeVisible()

  // Reload to prove the session and its active tab are derived from the
  // server-persisted Terminal::Session, not just client-side navigation state.
  await page.reload()
  await expect(page.getByRole("tab", { selected: true })).toHaveText(/^WF-\d+ workspace$/)
  await expect(page.getByText(/\.syrus\/workflows\/\d+$/)).toBeVisible()
})
