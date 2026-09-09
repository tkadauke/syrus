import { test, expect, type Locator, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { ONBOARDING_USER, signIn } from "./support/auth"

test.setTimeout(60_000)

test("first-run onboarding checklist updates through the golden path", async ({ page }) => {
  await signIn(page, ONBOARDING_USER)

  await expect(page).toHaveURL(/\/onboarding$/)
  await expect(page.getByRole("heading", { name: "Set up Syrus" })).toBeVisible()

  await expect(completedStep(page, "Account and admin access")).toBeVisible()
  await expect(incompleteStep(page, "How do you work?")).toBeVisible()
  await expect(incompleteStep(page, "GitHub integration")).toBeVisible()
  await expect(incompleteStep(page, "Agent credentials and provider")).toBeVisible()
  await expect(incompleteStep(page, "Repository")).toBeVisible()
  await expect(incompleteStep(page, "Meet Syrus")).toBeVisible()
  await expect(incompleteStep(page, "Land your first Epic")).toBeVisible()

  await page.goto("/dashboard/jobs")
  await expect(page).toHaveURL(/\/onboarding$/)

  const modeSaved = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/admin/settings") && response.request().method() === "PATCH" && response.ok()
  )
  await page.getByRole("button", { name: "Yes, I write code" }).click()
  await modeSaved
  await page.goto("/onboarding")
  await expect(completedStep(page, "How do you work?")).toBeVisible()
  await expect(incompleteStep(page, "GitHub integration")).toBeVisible()

  advanceOnboardingFixture("github")
  await page.goto("/onboarding")
  await expect(completedStep(page, "GitHub integration")).toBeVisible()
  await expect(incompleteStep(page, "Agent credentials and provider")).toBeVisible()

  advanceOnboardingFixture("agent")
  await page.goto("/onboarding")
  await expect(completedStep(page, "Agent credentials and provider")).toBeVisible()
  await expect(incompleteStep(page, "Repository")).toBeVisible()

  advanceOnboardingFixture("repository")
  await page.goto("/onboarding")
  await expect(completedStep(page, "Repository")).toBeVisible()
  await expect(incompleteStep(page, "Meet Syrus")).toBeVisible()

  const onboardingChat = page.waitForResponse((response) =>
    response.url().includes("/api/v1/app/chats/onboarding") && response.request().method() === "POST" && response.ok()
  )
  await page.getByRole("button", { name: "Start Syrus chat" }).click()
  await onboardingChat

  await page.goto("/onboarding")
  await expect(completedStep(page, "Meet Syrus")).toBeVisible()
  await expect(incompleteStep(page, "Land your first Epic")).toBeVisible()

  await page.goto("/dashboard/jobs")
  await expect(page).toHaveURL(/\/dashboard\/jobs/)
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()

  advanceOnboardingFixture("epic")
  await page.goto("/onboarding")
  await expect(completedStep(page, "Land your first Epic")).toBeVisible()
  await page.getByRole("link", { name: "Open Dashboard" }).click()
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
})

function completedStep(page: Page, title: string): Locator {
  return checklistStep(page, title).filter({ hasText: "Complete" })
}

function incompleteStep(page: Page, title: string): Locator {
  return checklistStep(page, title).filter({ hasNotText: "Complete" })
}

function checklistStep(page: Page, title: string): Locator {
  return page.locator("li").filter({ has: page.getByRole("heading", { name: title }) })
}

function advanceOnboardingFixture(step: "github" | "agent" | "repository" | "epic") {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The onboarding E2E fixture can only be advanced against the local test database.")
  }

  execFileSync("bin/rails", ["runner", onboardingFixtureScript(step)], {
    env: process.env,
    stdio: "inherit"
  })
}

function onboardingFixtureScript(step: "github" | "agent" | "repository" | "epic") {
  const email = ONBOARDING_USER.email
  if (step === "github") {
    return `
      user = User.find_by!(email_address: ${JSON.stringify(email)})
      user.update!(github_token: "ghp_e2e_onboarding")
      AppSetting.current.update!(github_app_id: 12_345, github_app_slug: "syrus-e2e", github_app_registered_at: Time.current)
    `
  }

  if (step === "agent") {
    return `
      User.find_by!(email_address: ${JSON.stringify(email)}).update!(codex_api_key: "sk-e2e-onboarding")
    `
  }

  if (step === "repository") {
    return `
      user = User.find_by!(email_address: ${JSON.stringify(email)})
      repository = Repository.find_or_initialize_by(owner: "e2e", name: "needs-onboarding")
      repository.assign_attributes(
        user: user,
        default_branch: "main",
        trigger_label: "syrus",
        polling_enabled: false,
        prepare_enabled: true,
        agent_provider: "codex",
        review_policy: "self",
        feedback_policy: "confirm",
        epic_dependency_policy: "linear"
      )
      repository.save!
    `
  }

  return `
    user = User.find_by!(email_address: ${JSON.stringify(email)})
    repository = Repository.find_by!(owner: "e2e", name: "needs-onboarding")
    epic = Epic.find_or_initialize_by(repository: repository, title: "E2E first Epic")
    epic.assign_attributes(user: user, owner_user: user, description: "E2E onboarding completion fixture.", state: "done", done_at: Time.current)
    epic.save!
  `
}
