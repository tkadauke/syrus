import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user finds the seeded demo Epic from the sidebar search box", async ({ page }) => {
  await signInAsDemo(page)

  // The demo Epic's full-text index rows (epic_fts) are populated by an
  // async IndexEpicSearchJob that only a worker process runs; the Playwright
  // preview server boots a bare `bin/rails server` with no worker, so a
  // free-text query against the seeded title would find nothing. The
  // EPIC-<number> slug match path (SearchController#epic_slug_rows) looks
  // the Epic up directly instead, so it works without a worker and is what
  // this spec exercises against the demo Epic seeded in db/seeds.rb.
  const searchBox = page.getByLabel("Search Syrus")
  await searchBox.fill("EPIC-1")
  await searchBox.press("Enter")

  await page.waitForURL((url) => url.pathname === "/search")
  await expect(page.getByRole("heading", { name: "Search", level: 1 })).toBeVisible()

  const epicResult = page.getByRole("article").filter({ has: page.getByRole("link", { name: "Preview the operator workflow" }) })
  await expect(epicResult).toBeVisible()
  await expect(epicResult.getByText("demo/syrus-preview")).toBeVisible()
})
