import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { DEMO_USER, signInAsDemo } from "./support/auth"

test.slow()

test("edits settings, provider defaults, locale, and theme preferences", async ({ page }) => {
  skipWhenRemote()
  resetDemoAccountSettings()

  await signInAsDemo(page)

  try {
    await page.goto("/profile")
    await expect(page.getByRole("main", { name: "Profile" })).toBeVisible()

    const profileSaved = page.waitForResponse((response) =>
      response.url().includes("/api/v1/app/credentials") && response.request().method() === "PATCH" && response.ok()
    )
    await page.getByLabel("Display name").fill("Demo Settings Operator")
    await page.getByLabel("First name").fill("Settings")
    await page.getByLabel("Last name").fill("Operator")
    await page.getByLabel("Company").fill("Syrus E2E")
    await page.getByLabel("Location").fill("Test Lab")
    await page.getByLabel("GitHub handle").fill("syrus-e2e")
    await page.getByLabel("Profile bio").fill("Exercises the settings golden path.")
    await page.getByRole("main").getByRole("button", { name: "Save" }).click()
    await profileSaved
    await expect(page.getByText("Profile updated.")).toBeVisible()

    await page.reload()
    await expect(page.getByLabel("Display name")).toHaveValue("Demo Settings Operator")
    await expect(page.getByLabel("Company")).toHaveValue("Syrus E2E")
    await expect(page.getByLabel("Profile bio")).toHaveValue("Exercises the settings golden path.")

    await page.goto("/credentials")
    await expect(page.getByRole("main", { name: "Credentials" })).toBeVisible()
    await expect(page.getByTestId("credential-card-github").getByRole("heading", { name: "GitHub" })).toBeVisible()
    await expect(page.getByTestId("credential-card-codex").getByRole("heading", { name: "Codex" })).toBeVisible()
    await expect(page.getByTestId("credential-card-codex")).toContainText("Connected")

    await page.goto("/settings/agent")
    await expect(page.getByRole("main", { name: "Agent Settings" })).toBeVisible()
    const agentSaved = page.waitForResponse((response) =>
      response.url().includes("/api/v1/app/credentials") && response.request().method() === "PATCH" && response.ok()
    )
    await page.getByLabel("Agent provider").selectOption("claude")
    await page.getByRole("main").getByRole("button", { name: "Save" }).click()
    await agentSaved
    await expect(page.getByText("Agent settings updated.")).toBeVisible()

    await page.reload()
    await expect(page.getByLabel("Agent provider")).toHaveValue("claude")

    await selectThemeMode(page, "Dark")
    await expect(page.locator("html")).toHaveClass(/dark/)

    await selectColorTheme(page, "Ocean")
    await expect(page.locator("html")).toHaveAttribute("data-theme", "ocean")

    await page.goto("/settings/preferences")
    await expect(page.getByRole("main", { name: "Preferences" })).toBeVisible()
    const preferencesSaved = page.waitForResponse((response) =>
      response.url().includes("/api/v1/app/credentials") && response.request().method() === "PATCH" && response.ok()
    )
    await page.getByLabel("Language").selectOption("de")
    await page.locator("main form button[type='submit']").click()
    await preferencesSaved

    await page.reload()
    await expect(page.locator("main select").first()).toHaveValue("de")
    await expect(page.locator("html")).toHaveClass(/dark/)
    await expect(page.locator("html")).toHaveAttribute("data-theme", "ocean")
  } finally {
    resetDemoAccountSettings()
  }
})

async function selectThemeMode(page: Page, mode: "Light" | "Dark" | "System") {
  await page.getByRole("button", { name: DEMO_USER.email }).click()
  const saved = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/theme") && response.request().method() === "PATCH" && response.ok()
  )
  await page.getByRole("button", { name: mode, exact: true }).click()
  await saved
  await expect(page.getByRole("button", { name: mode, exact: true })).toHaveAttribute("aria-pressed", "true")
  await page.keyboard.press("Escape")
}

async function selectColorTheme(page: Page, name: "Ocean") {
  await page.getByRole("button", { name: DEMO_USER.email }).click()
  await page.getByRole("button", { name: /Color theme:/ }).click()
  const saved = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/theme") && response.request().method() === "PATCH" && response.ok()
  )
  await page.getByRole("button", { name, exact: true }).click()
  await saved
  await expect(page.getByRole("button", { name, exact: true })).toHaveAttribute("aria-pressed", "true")
  await page.keyboard.press("Escape")
}

function skipWhenRemote() {
  test.skip(!!process.env.E2E_BASE_URL, "Settings E2E mutates local preview fixture user preferences.")
}

function resetDemoAccountSettings() {
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
      codex_auth_mode: "api_key",
      codex_api_key: "sk-e2e-codex",
      theme: "system",
      color_theme: Theme.find_by!(slug: "terracotta"),
      locale: "en",
      scheduling_paused: false
    )
  `], {
    env: {
      ...process.env,
      BUNDLE_PATH: `${process.cwd()}/vendor/bundle`,
      BUNDLE_APP_CONFIG: `${process.cwd()}/.bundle`
    },
    stdio: "inherit"
  })
}
