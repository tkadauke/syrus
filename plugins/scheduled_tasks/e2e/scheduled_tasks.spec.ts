import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can open the Schedules page", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/scheduled_tasks")

  await expect(page.getByRole("heading", { name: "Scheduled tasks" })).toBeVisible()
})
