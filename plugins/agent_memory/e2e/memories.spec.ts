import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user can view a repository memory entry from the list and its detail", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/memories")
  await expect(page.getByRole("heading", { name: "Memories", level: 1 })).toBeVisible()

  const emptyState = page.getByText("No memories match these filters.")
  const memoryRows = page.locator("table tbody tr").filter({ has: page.getByRole("button", { name: "See more" }) })

  // Wait for the memories query to settle on whichever state it lands in
  // before deciding whether a fixture entry needs seeding.
  await expect(emptyState.or(memoryRows.first())).toBeVisible()

  if (await emptyState.isVisible()) {
    const content = `E2E fixture memory: prefer terse status updates in chat. (${Date.now()})`

    await page.getByRole("button", { name: "Create memory", exact: true }).click()

    const createDialog = page.getByRole("dialog", { name: "Create memory" })
    await createDialog.locator("#memory-scope").selectOption({ label: "Repository" })
    await createDialog.locator("#memory-repository").selectOption({ label: "demo/syrus-preview" })
    await createDialog.locator("#memory-content").fill(content)
    await createDialog.getByRole("button", { name: "Save", exact: true }).click()

    await expect(emptyState).not.toBeVisible()
  }

  // Reuses whichever entry now sorts first (freshly seeded or pre-existing)
  // and cross-checks the list preview against the detail modal so the same
  // content is asserted to render correctly in both places.
  const row = memoryRows.first()
  const previewText = (await row.locator(".line-clamp-2").textContent())?.trim() ?? ""
  expect(previewText.length).toBeGreaterThan(0)

  await row.getByRole("button", { name: "See more" }).click()

  const detailDialog = page.getByRole("dialog", { name: "Memory content" })
  await expect(detailDialog).toBeVisible()
  await expect(detailDialog).toContainText(previewText)
})
