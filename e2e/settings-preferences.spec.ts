import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { DEMO_USER, signInAsDemo } from "./support/auth"

test.slow()

test("edits settings and persists user preferences across reloads", async ({ page }) => {
  skipWhenRemote()
  resetDemoUserSettings()

  await signInAsDemo(page)

  try {
    await page.goto("/profile")
    const profile = page.getByRole("main", { name: "Profile" })
    await expect(profile).toBeVisible()

    await profile.getByLabel("Display name").fill("Demo Settings Operator")
    await profile.getByLabel("First name").fill("Settings")
    await profile.getByLabel("Last name").fill("Operator")
    await profile.getByLabel("Company").fill("Syrus E2E")
    await profile.getByLabel("Location").fill("Golden Path Lab")
    await profile.getByLabel("GitHub handle").fill("settings-demo")
    const profileSaved = waitForCredentialsSave(page)
    await profile.getByRole("button", { name: "Save" }).click()
    await profileSaved

    await page.reload()
    await expect(page.getByRole("main", { name: "Profile" }).getByLabel("Display name")).toHaveValue("Demo Settings Operator")
    await expect(page.getByRole("main", { name: "Profile" }).getByLabel("Company")).toHaveValue("Syrus E2E")

    await page.goto("/settings/agent")
    const agentSettings = page.getByRole("main", { name: "Agent Settings" })
    await expect(agentSettings).toBeVisible()
    await agentSettings.getByLabel("Agent provider").selectOption("claude")
    await agentSettings.getByLabel("Max turns").fill("24")
    const agentSaved = waitForCredentialsSave(page)
    await agentSettings.getByRole("button", { name: "Save" }).click()
    await agentSaved

    await page.reload()
    await expect(page.getByRole("main", { name: "Agent Settings" }).getByLabel("Agent provider")).toHaveValue("claude")
    await expect(page.getByRole("main", { name: "Agent Settings" }).getByLabel("Max turns")).toHaveValue("24")

    await page.goto("/dashboard/jobs")
    await setShellTheme(page, "Dark")
    await setShellColorTheme(page, "Ocean")

    await page.reload()
    await expect(page.locator("html")).toHaveClass(/dark/)
    await expect(page.locator("html")).toHaveAttribute("data-theme", "ocean")

    await openAccountMenu(page)
    await expect(page.getByRole("group", { name: "Theme" }).getByRole("button", { name: "Dark" })).toHaveAttribute("aria-pressed", "true")
    await page.getByRole("button", { name: /Color theme: Ocean/ }).click()
    await expect(page.getByRole("group", { name: "Color theme" }).getByRole("button", { name: "Ocean", exact: true })).toHaveAttribute("aria-pressed", "true")

    await page.goto("/settings/preferences")
    const preferences = page.locator("main")
    await expect(page.getByRole("main", { name: "Preferences" })).toBeVisible()
    await preferences.getByLabel("Language").selectOption("de")
    const preferencesSaved = waitForCredentialsSave(page)
    await preferences.locator("button[type='submit']").click()
    await preferencesSaved

    await page.reload()
    await expect(page.getByRole("navigation", { name: "Primär" })).toBeVisible()
    await expect(page.locator("main select").first()).toHaveValue("de")
  } finally {
    resetDemoUserSettings()
  }
})

async function setShellTheme(page: Page, label: "Light" | "Dark" | "System") {
  await openAccountMenu(page)
  const themeSaved = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/theme") && response.request().method() === "PATCH" && response.ok()
  )
  await page.getByRole("group", { name: "Theme" }).getByRole("button", { name: label }).click()
  await themeSaved
}

async function setShellColorTheme(page: Page, label: string) {
  await openAccountMenu(page)
  await page.getByRole("button", { name: /Color theme:/ }).click()
  const colorThemeSaved = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/theme") && response.request().method() === "PATCH" && response.ok()
  )
  await page.getByRole("group", { name: "Color theme" }).getByRole("button", { name: label }).click()
  await colorThemeSaved
}

async function openAccountMenu(page: Page) {
  const accountButton = page.getByRole("button", { name: DEMO_USER.email })
  if ((await accountButton.getAttribute("aria-expanded")) !== "true") {
    await accountButton.click()
  }
}

function waitForCredentialsSave(page: Page) {
  return page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/credentials") && response.request().method() === "PATCH" && response.ok()
  )
}

function skipWhenRemote() {
  test.skip(!!process.env.E2E_BASE_URL, "Settings E2E mutates local preview fixture data.")
}

function resetDemoUserSettings() {
  execFileSync("bin/rails", ["runner", `
    user = User.find_by!(email_address: ${JSON.stringify(DEMO_USER.email)})
    user.update!(
      name: "Demo Operator",
      first_name: "Demo",
      last_name: "Operator",
      profile_company: nil,
      profile_location: nil,
      profile_website: nil,
      github_handle: nil,
      profile_bio: nil,
      avatar_url: nil,
      role: "developer",
      agent_provider: "codex",
      chat_provider: "codex",
      agent_max_turns: 10,
      scheduling_paused: false,
      auto_approve_mode: "never",
      locale: "en",
      theme: "system",
      color_theme: Theme.terracotta
    )
  `], {
    env: process.env
  })
}
