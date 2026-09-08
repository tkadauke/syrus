import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

// Wide enough viewport to clear both AppChromeV2's lg (1024px) sidebar
// breakpoint and ChatWorkspace's own 1280px split-view breakpoint
// (CHAT_WORKSPACE_SPLIT_MIN_WIDTH), so the workspace tabs render inline
// instead of collapsing to the mobile tab bar.
test.use({ viewport: { width: 1400, height: 900 } })

test("signed-in user can draw a shape on a chat's whiteboard and see it persist across reload", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/dashboard")
  await page.getByRole("button", { name: "New Chat", exact: true }).click()
  await expect(page).toHaveURL(/\/chats\/(\d+)$/)
  const chatId = page.url().match(/\/chats\/(\d+)$/)?.[1]

  // The workspace side panel starts collapsed; open it, then switch to the
  // plugin-registered Whiteboard tab (available on every chat).
  await page.getByRole("button", { name: "Open workspace panel" }).click()
  await page.getByRole("button", { name: "Whiteboard", exact: true }).click()
  await expect(page.getByText("Empty canvas. Start sketching, or ask the agent to draw something.")).toBeVisible()

  // The toolbar test id lands on the underlying <input type="radio">, whose
  // icon overlay intercepts a normal click.
  await page.getByTestId("toolbar-rectangle").click({ force: true })
  const canvas = page.locator(".excalidraw__canvas.interactive")
  const box = await canvas.boundingBox()
  if (!box) throw new Error("Whiteboard canvas did not render.")

  const whiteboardSaved = page.waitForResponse(
    (response) => response.request().method() === "PATCH" && response.url().includes(`/api/v1/app/chats/${chatId}/whiteboard`)
  )
  await page.mouse.move(box.x + 80, box.y + 80)
  await page.mouse.down()
  await page.mouse.move(box.x + 260, box.y + 240, { steps: 10 })
  await page.mouse.up()
  await whiteboardSaved

  await expect(page.getByText("1 canvas element")).toBeVisible()

  // Reload to prove the drawn shape (the Excalidraw scene) persisted
  // server-side, not just in client-side React state. The workspace panel
  // and active tab preferences are stored in localStorage, so both survive
  // the reload without re-clicking.
  await page.reload()
  await expect(page.getByText("1 canvas element")).toBeVisible()
})
