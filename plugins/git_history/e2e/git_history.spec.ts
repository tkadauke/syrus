import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user views a repository's Git History tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  await page.getByRole("navigation", { name: "Repository tabs" }).getByRole("link", { name: "Git History", exact: true }).click()

  await expect(page.getByRole("heading", { name: "demo/syrus-preview", level: 1 })).toBeVisible()

  const main = page.getByRole("main", { name: "Git history" })
  await expect(main).toBeVisible()

  // The relay that serves commit history (GitHistory::RelayServer) only ever
  // starts on a worker process with SYRUS_ROLE=worker consuming the
  // `polling` queue -- see plugins/git_history/docs/syrus_docs/git_history.md.
  // The Playwright preview server (bin/syrus-preview-dev) boots only a bare
  // `bin/rails server`, no worker process at all, so the relay never starts
  // and `available` is always false here -- the same real "not there yet"
  // state Build Cache's admin page exercises for its unconfigured bucket,
  // rather than faking a synced bare clone just to show commit rows.
  await expect(main.getByText("Git history is not available yet for this repository.", { exact: false })).toBeVisible()
})
