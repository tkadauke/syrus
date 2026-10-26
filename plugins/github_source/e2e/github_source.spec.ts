import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

// This dev sandbox seeds a demo repository and demo Jobs (db/seeds.rb) but
// deliberately has no GitHub App registration (see .syrus.yml's
// visual_review.seed_notes). The repository overview should render that
// connection state, while the Issues tab reads the poll-synchronized cache.
test("signed-in user sees the repository's GitHub connection state and cached Issues tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await expect(page).toHaveURL(/\/repositories\/\d+$/)
  await expect(page.getByRole("heading", { name: "demo/syrus-preview", level: 1 })).toBeVisible()

  // GitHub App connection settings on the repository overview: no App is
  // registered for this instance and the repo has no active installation,
  // so it falls back to PAT mode and offers to register the App.
  await expect(page.getByText("PAT fallback because this repository has no active App installation.")).toBeVisible()
  await expect(page.getByRole("link", { name: "Register Syrus App" })).toBeVisible()

  // GitHub Issues tab: listing reads the local issue cache and does not require
  // a live GitHub client merely to display its empty state.
  await page.getByRole("link", { name: "GitHub Issues", exact: true }).click()
  await expect(page).toHaveURL(/\/repositories\/\d+\/plugin\/issues$/)
  await expect(page.getByRole("heading", { name: "No issues in Open" })).toBeVisible()

  // Reload to prove the cached empty state is derived server-side on every
  // load, not just an artifact of client-side tab navigation.
  await page.reload()
  await expect(page.getByRole("heading", { name: "No issues in Open" })).toBeVisible()
})

test("signed-in user browses the fixture-backed source on a Job's Source tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await page.getByRole("link", { name: "Inspect preview dashboard states" }).click()
  await expect(page).toHaveURL(/\/jobs\/(\d+)$/)

  // The seeded demo Job carries a development-only diff fixture that also
  // backs the Source tab, so the repository (which has no GitHub token or
  // installation) still renders the source browser instead of the
  // "not configured" empty state.
  await page.getByRole("button", { name: "Source", exact: true }).click()
  // The Source tab is its own route (App.tsx: "/jobs/:id/source"), not a
  // ?tab= query parameter.
  await expect(page).toHaveURL(/\/jobs\/\d+\/source$/)
  await expect(page.getByText("Viewing")).toBeVisible()
  await expect(page.getByText("GitHub token not configured. Add one in Settings to browse source.")).toHaveCount(0)

  await page.reload()
  await expect(page.getByText("Viewing")).toBeVisible()
  await expect(page.getByText("GitHub token not configured. Add one in Settings to browse source.")).toHaveCount(0)
})
