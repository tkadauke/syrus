import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in admin sees the instance-wide spend rollup on Spending Insights", async ({ page }) => {
  await signInAsDemo(page)

  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Spending" }).click()

  await expect(page.getByRole("heading", { name: "Spending", level: 1 })).toBeVisible()

  const main = page.getByRole("main", { name: "Spending insights" })

  // Demo user is a global admin, so the scope line rolls up spend across
  // every user rather than scoping to just their own runs.
  await expect(main.getByText(/All users/)).toBeVisible()

  const totals = main.getByRole("region", { name: "Spending totals" })
  await expect(totals.getByText("This week")).toBeVisible()
  await expect(totals.getByText("Lifetime")).toBeVisible()

  // The seeded "Inspect preview dashboard states" job carries a costed
  // implement/summarize/test_plan Run chain against demo/syrus-preview,
  // trigger_kind "initial", agent_provider "codex" -- exercising the repo,
  // trigger kind, and provider rollups the issue asks for.
  const repositoryBreakdown = page.getByRole("region", { name: "By Repository" })
  const repositoryRow = repositoryBreakdown.locator("tr").filter({ has: page.getByRole("link", { name: "demo/syrus-preview" }) })
  await expect(repositoryRow).toBeVisible()
  await expect(repositoryRow.getByText("$0.13").first()).toBeVisible()

  const triggerBreakdown = page.getByRole("region", { name: "By Trigger kind" })
  const initialRow = triggerBreakdown.locator("tr").filter({ hasText: "Initial" })
  await expect(initialRow).toBeVisible()
  await expect(initialRow.getByText("$0.13")).toBeVisible()

  const topRuns = page.getByRole("region", { name: "Top runs" })
  await expect(topRuns.getByText("Initial / codex").first()).toBeVisible()
})
