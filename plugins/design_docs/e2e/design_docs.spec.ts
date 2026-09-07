import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can create a design doc, comment on it, and see it persist", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/design_docs")
  await expect(page.getByRole("heading", { name: "Design Docs", level: 1 })).toBeVisible()

  await page.getByRole("button", { name: "New doc", exact: true }).click()
  await expect(page).toHaveURL(/\/design_docs\/(\d+)$/)
  const docId = page.url().match(/\/design_docs\/(\d+)$/)?.[1]

  // Editor pane for the newly created doc.
  await expect(page.getByLabel("Design doc title", { exact: true })).toHaveValue("Untitled design doc")

  // List/editor split surface: the new doc shows up in the index list too.
  await page.goto("/design_docs")
  await expect(page.getByRole("button").filter({ hasText: `DOC-${docId}` })).toBeVisible()
  await page.getByRole("button").filter({ hasText: `DOC-${docId}` }).click()
  await expect(page).toHaveURL(`/design_docs/${docId}`)

  const title = `E2E design doc ${Date.now()}`
  const titleSaved = page.waitForResponse(
    (response) => response.request().method() === "PATCH" && response.url().includes(`/api/v1/app/design_docs/${docId}`)
  )
  await page.getByLabel("Design doc title", { exact: true }).fill(title)
  await titleSaved

  // Select the doc body's heading text to open the inline comment composer.
  await page.getByRole("heading", { name: "Untitled design doc", level: 1 }).click({ clickCount: 3 })

  const commentText = `E2E comment ${Date.now()}`
  await page.getByLabel("New thread comment").fill(commentText)
  const commentSaved = page.waitForResponse(
    (response) => response.request().method() === "POST" && response.url().includes(`/api/v1/app/design_docs/${docId}/comments`)
  )
  await page.getByRole("button", { name: "Comment", exact: true }).click()
  await commentSaved

  await expect(page.getByText(commentText)).toBeVisible()

  // Reload to prove both the title change and the comment persisted server-side.
  await page.reload()
  await expect(page.getByLabel("Design doc title", { exact: true })).toHaveValue(title)
  await expect(page.getByText(commentText)).toBeVisible()
})
