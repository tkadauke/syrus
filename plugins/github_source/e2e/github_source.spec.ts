import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

// This dev sandbox seeds a demo repository and demo Jobs (db/seeds.rb) but
// deliberately has no GitHub App registration and no user github_token (see
// .syrus.yml's visual_review.seed_notes). So both GitHub Source plugin
// surfaces should render their "not configured" states rather than error out.
test("signed-in user sees the not-configured state on the repository's GitHub Issues tab and connection settings", async ({ page }) => {
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

  // GitHub Issues tab: listing issues requires a real GitHub client, which
  // is unavailable here, so the tab reports the same "not configured" state
  // instead of a raw API failure.
  await page.getByRole("link", { name: "GitHub Issues", exact: true }).click()
  await expect(page).toHaveURL(/\/repositories\/\d+\/plugin\/issues$/)
  await expect(page.getByText("No GitHub token configured — add one in Settings.")).toBeVisible()

  // Reload to prove the empty state is derived server-side on every load,
  // not just an artifact of client-side tab navigation.
  await page.reload()
  await expect(page.getByText("No GitHub token configured — add one in Settings.")).toBeVisible()
})

test("signed-in user sees the not-configured state on a Job's Source tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()
  await page.getByRole("link", { name: "Inspect preview dashboard states" }).click()
  await expect(page).toHaveURL(/\/jobs\/(\d+)$/)

  // Unlike this same Job's Review tab (backed by a diff fixture for preview
  // purposes), the Source tab browses live GitHub content and has no
  // fixture, so it must show the "not configured" empty state here too.
  await page.getByRole("button", { name: "Source", exact: true }).click()
  await expect(page).toHaveURL(/\/jobs\/\d+\?tab=source$/)
  await expect(page.getByText("GitHub token not configured. Add one in Settings to browse source.")).toBeVisible()

  await page.reload()
  await expect(page.getByText("GitHub token not configured. Add one in Settings to browse source.")).toBeVisible()
})
