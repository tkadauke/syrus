import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

// The terminal plugin is off by default -- a terminal session is a real
// shell on the worker, so an operator has to opt in. No worker/PTY runs in
// this preview sandbox (see .syrus.yml's visual_review.seed_notes), so once
// a session is opened the test only asserts on what the UI renders without a
// live PTY: the panel opening with the right chrome, not any real output.
test("signed-in admin enables the Terminal plugin and opens a session panel from a Job's workflow", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/dashboard")
  const primaryNav = page.getByRole("navigation", { name: "Primary" })
  await expect(primaryNav.getByRole("link", { name: "Terminal" })).toHaveCount(0)

  await page.goto("/admin/plugins")
  const terminalCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "Terminal", exact: true }) })
  await expect(terminalCard.getByText("Disabled", { exact: true }).first()).toBeVisible()
  await terminalCard.getByRole("button", { name: "Enable" }).click()

  // Enabling reloads the SPA -- a plugin's sidebar page and ui_slot only
  // resolve on a fresh boot -- so re-find the card after the reload lands.
  await expect(page.getByRole("heading", { name: "Plugins", level: 1 })).toBeVisible()
  const enabledTerminalCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "Terminal", exact: true }) })
  await expect(enabledTerminalCard.getByText("Enabled", { exact: true }).first()).toBeVisible()

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
