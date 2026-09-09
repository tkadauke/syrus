import { test, expect, type Locator, type Page } from "@playwright/test"
import { ONBOARDING_USER, signIn } from "./support/auth"

test("first-run onboarding checklist updates when the chat starts", async ({ page }) => {
  await signIn(page, ONBOARDING_USER)

  await expect(page).toHaveURL(/\/onboarding$/)
  await expect(page.getByRole("heading", { name: "Set up Syrus" })).toBeVisible()

  await expect(completedStep(page, "Account and admin access")).toBeVisible()
  await expect(completedStep(page, "How do you work?")).toBeVisible()
  await expect(completedStep(page, "GitHub integration")).toBeVisible()
  await expect(completedStep(page, "Agent credentials and provider")).toBeVisible()
  await expect(completedStep(page, "Repository")).toBeVisible()
  await expect(incompleteStep(page, "Meet Syrus")).toBeVisible()
  await expect(incompleteStep(page, "Land your first Epic")).toBeVisible()

  await page.goto("/dashboard/jobs")
  await expect(page).toHaveURL(/\/onboarding$/)

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
