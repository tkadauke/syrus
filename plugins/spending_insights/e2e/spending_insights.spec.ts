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
  const repositoryRow = page.getByRole("row", { name: /^demo\/syrus-preview\s+1\s+\$0\.13\s+\$0\.13$/ })
  await expect(repositoryRow).toBeVisible()
  await expect(repositoryRow.getByText("$0.13").first()).toBeVisible()

  // The repository rollup above is scoped to the seeded repository, so its
  // total is exactly the seeded Run chain's. This one rolls up every
  // repository in the instance, so assert that the seeded Runs land in the
  // Initial row and that it is costed -- the amount itself belongs to
  // whatever else the database holds.
  const initialRow = page.getByRole("row", { name: /^Initial\s+\d+\s+\$\d+\.\d{2}\s+\$\d+\.\d{2}$/ })
  await expect(initialRow).toBeVisible()
  await expect(initialRow.getByText(/^\$\d+\.\d{2}$/).first()).toBeVisible()

  await expect(main.getByText("Initial / codex").first()).toBeVisible()
})
