import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test("dashboard shows the seeded epic", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/dashboard/epics")

  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
  await expect(page.getByText("Preview the operator workflow")).toBeVisible()
})
