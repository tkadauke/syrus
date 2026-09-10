import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Builds on the seeded demo Epic (JOB-4413) by exercising the operator-facing
// Epic creation and management flows end to end: creating an Epic, adding
// child Jobs to it, chaining their dependencies (and getting rejected when
// that would break the linear-chain policy -- see JobDependency#linear_chain_within_epic),
// viewing the Epic detail page, and editing Epic metadata. Each test creates
// its own Epic/Jobs with a timestamped title so runs never collide with the
// seeded fixture data or with each other -- db:prepare never truncates the
// dev database (same convention as job-lifecycle.spec.ts).
test.slow()

test("creates an Epic with child Jobs from the UI and lists them on the Epic detail page", async ({ page }) => {
  await signInAsDemo(page)

  const epicTitle = `E2E epic ${Date.now()}`
  const epicId = await createEpic(page, epicTitle, "Small Epic exercised by Playwright.")

  const jobATitle = `${epicTitle} - child A`
  const jobBTitle = `${epicTitle} - child B`
  await addChildJob(page, epicId, jobATitle, "First child job in the Epic.")
  await addChildJob(page, epicId, jobBTitle, "Second child job in the Epic.")

  await page.goto(`/epics/${epicId}`)
  await expect(page.getByRole("heading", { level: 1 })).toContainText(epicTitle)
  await expect(page.getByRole("link", { name: jobATitle })).toBeVisible()
  await expect(page.getByRole("link", { name: jobBTitle })).toBeVisible()
  await expect(page.getByText("2 Jobs")).toBeVisible()

  // The Epic detail page's dependency graph section covers dependencies on
  // other Epics/external Jobs -- these two freshly created, unchained child
  // Jobs shouldn't produce any of those.
  await expect(page.getByText("No external dependencies")).toBeVisible()
})

test("enforces the linear-chain dependency policy when chaining child Jobs (no fan-out/fan-in)", async ({ page }) => {
  await signInAsDemo(page)

  const epicTitle = `E2E chain ${Date.now()}`
  const epicId = await createEpic(page, epicTitle, "Exercises the linear-chain dependency policy.")

  const jobATitle = `${epicTitle} - job A`
  const jobBTitle = `${epicTitle} - job B`
  const jobCTitle = `${epicTitle} - job C`
  const jobAId = await addChildJob(page, epicId, jobATitle, "Upstream job.")
  const jobBId = await addChildJob(page, epicId, jobBTitle, "Depends on job A.")
  const jobCId = await addChildJob(page, epicId, jobCTitle, "Attempts to also depend on job A.")

  // B -> A is a valid, single-link chain.
  await addDependency(page, jobBId, jobATitle)
  await expect(page.getByRole("button", { name: `Copy JOB-${jobAId} to clipboard` }).first()).toBeVisible()

  // C -> A would fork the chain: A would have two downstream Jobs (fan-out).
  await addDependency(page, jobCId, jobATitle)
  await expect(page.getByText(/must form a single chain/)).toBeVisible()
  await expect(page.getByText("No dependencies.")).toBeVisible()

  // B -> C would merge two upstream Jobs into B, which already depends on A
  // (fan-in).
  await addDependency(page, jobBId, jobCTitle)
  await expect(page.getByText(/must form a single chain/)).toBeVisible()
  await expect(page.getByRole("button", { name: `Copy JOB-${jobAId} to clipboard` }).first()).toBeVisible()
  await expect(page.getByRole("button", { name: `Copy JOB-${jobCId} to clipboard` })).toHaveCount(0)
})

test("edits an Epic's metadata", async ({ page }) => {
  await signInAsDemo(page)

  const originalTitle = `E2E epic edit ${Date.now()}`
  const epicId = await createEpic(page, originalTitle, "Original description.")

  await page.getByRole("link", { name: "Edit" }).click()
  await expect(page.getByRole("heading", { name: "Edit Epic" })).toBeVisible()

  const updatedTitle = `${originalTitle} (updated)`
  await page.getByLabel("Title").fill(updatedTitle)
  await page.getByLabel("Description").fill("Updated description from Playwright.")
  await page.getByRole("button", { name: "Save Epic", exact: true }).click()

  await page.waitForURL(`/epics/${epicId}`)
  await expect(page.getByRole("heading", { level: 1 })).toContainText(updatedTitle)
  await expect(page.getByRole("paragraph").filter({ hasText: "Updated description from Playwright." })).toBeVisible()
})

async function createEpic(page: Page, title: string, description: string): Promise<number> {
  await page.goto("/epics/new")
  await page.getByLabel("Title").fill(title)
  await page.getByLabel("Description").fill(description)
  await page.getByLabel(/repository/i).selectOption({ label: "demo/syrus-preview" })
  await page.getByRole("button", { name: "Create Epic", exact: true }).click()

  await page.waitForURL(/\/epics\/\d+$/)
  return idFromUrl(page)
}

async function addChildJob(page: Page, epicId: number, title: string, prompt: string): Promise<number> {
  await page.goto(`/epics/${epicId}`)
  await page.getByRole("link", { name: "+ Add Job" }).click()
  await expect(page.getByText("This job will be added to")).toBeVisible()

  await page.getByLabel("Title").fill(title)
  await page.getByPlaceholder(/describe what you want the agent to do/i).fill(prompt)
  await page.getByRole("button", { name: "Create job", exact: true }).click()

  await page.waitForURL(/\/jobs\/\d+$/)
  return idFromUrl(page)
}

async function addDependency(page: Page, jobId: number, dependencyTitle: string) {
  await page.goto(`/jobs/${jobId}`)
  await page.getByRole("button", { name: "+ Add dependency", exact: true }).click()
  await page.getByRole("searchbox", { name: "Search Jobs or issues" }).fill(dependencyTitle)
  await page.getByRole("button", { name: dependencyTitle }).click()
}

function idFromUrl(page: Page): number {
  const match = new URL(page.url()).pathname.match(/(\d+)$/)
  if (!match) throw new Error(`Expected an id in the URL, got ${page.url()}`)

  return Number(match[1])
}
