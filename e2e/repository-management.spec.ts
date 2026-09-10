import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { DEMO_USER, signInAsDemo } from "./support/auth"

test.slow()

test("adds a repository with automation settings from the UI", async ({ page }) => {
  skipWhenRemote()

  const stamp = Date.now()
  const owner = `e2e-${stamp}`
  const name = "repository-settings"

  await signInAsDemo(page)

  try {
    await page.goto("/repositories/new")

    await expect(page.getByRole("main", { name: "Add Repository" })).toBeVisible()
    await expect(page.getByText("No GitHub token configured. Enter the repository manually or add a token in Credentials.")).toBeVisible()

    const main = page.getByRole("main", { name: "Add Repository" })
    await main.getByLabel("Working owner").fill(owner)
    await main.getByLabel("Working name").fill(name)
    await main.getByLabel("Default branch", { exact: true }).fill("main")
    await main.getByLabel("Trigger label").first().fill("delegate")
    await main.getByLabel("Default agent").selectOption("codex")
    await main.getByLabel("Feedback policy").selectOption("auto")
    await main.getByLabel("Review policy").selectOption("two_person")

    await page.getByRole("button", { name: "Create Repository", exact: true }).click()
    await page.waitForURL(/\/repositories$/)

    const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: `${owner}/${name}`, exact: true }) })
    await expect(row).toBeVisible()
    await expect(row).toContainText("delegate")
    await expect(row).toContainText("Codex")
  } finally {
    deleteRepository(owner, name)
  }
})

test("edits the seeded repository settings and shows config plus unconfigured GitHub App state", async ({ page }) => {
  skipWhenRemote()
  const repositoryId = resetDemoRepositorySettings()

  await signInAsDemo(page)

  try {
    await openDemoRepository(page, repositoryId)

    await expect(page.getByRole("heading", { level: 1 })).toContainText("demo/syrus-preview")
    await expect(page.getByText("polling paused")).toBeVisible()
    await expect(page.getByText("PAT fallback: no active App installation")).toBeVisible()
    await expect(page.getByText("Register the GitHub App to prefer app credentials over PAT fallback.")).toBeVisible()

    const details = page.getByRole("region", { name: "Repository details" })
    await expect(details).toContainText("demo/syrus-preview")
    await expect(details).toContainText("main")
    await expect(details).toContainText("syrus")

    const config = page.getByRole("region", { name: ".syrus.yml configuration" })
    await expect(config).toContainText(".syrus.yml")
    await expect(config).toContainText("no GitHub credentials")

    await page.getByRole("button", { name: "More" }).click()
    await page.getByRole("link", { name: "Edit" }).click()

    await expect(page.getByRole("main", { name: "Edit Repository" })).toBeVisible()
    const main = page.getByRole("main", { name: "Edit Repository" })
    await expect(main.getByLabel("Working owner")).toHaveValue("demo")
    await expect(main.getByLabel("Working name")).toHaveValue("syrus-preview")
    await expect(main.getByLabel("Trigger label").first()).toHaveValue("syrus")
    await expect(main.getByLabel("Default agent")).toHaveValue("codex")
    await expect(main.getByLabel("Feedback policy")).toHaveValue("confirm")
    await expect(main.getByLabel("Review policy")).toHaveValue("self")

    await main.getByLabel("Trigger label").first().fill("review-me")
    await main.getByLabel("Feedback policy").selectOption("auto")
    await main.getByLabel("Review policy").selectOption("two_person")
    await page.getByRole("button", { name: "Save Repository", exact: true }).click()

    await page.waitForURL(/\/repositories$/)
    const row = page.getByRole("row").filter({ has: page.getByRole("link", { name: "demo/syrus-preview", exact: true }) })
    await expect(row).toContainText("review-me")

    await openDemoRepository(page, repositoryId)
    await expect(page.getByRole("region", { name: "Repository details" })).toContainText("review-me")
  } finally {
    resetDemoRepositorySettings()
  }
})

async function openDemoRepository(page: Page, repositoryId: number) {
  await page.goto(`/repositories/${repositoryId}`)
  await expect(page.getByRole("heading", { level: 1 })).toContainText("demo/syrus-preview")
}

function skipWhenRemote() {
  test.skip(!!process.env.E2E_BASE_URL, "Repository management E2E mutates local preview fixture data.")
}

function resetDemoRepositorySettings(): number {
  const output = execFileSync("bin/rails", ["runner", `
    user = User.find_by!(email_address: ${JSON.stringify(DEMO_USER.email)})
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")
    repository.update!(
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
    puts repository.id
  `], {
    env: process.env
  }).toString().trim()

  return Number(output)
}

function deleteRepository(owner: string, name: string) {
  execFileSync("bin/rails", ["runner", `
    Repository.find_by(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)})&.destroy!
  `], {
    env: process.env
  })
}
