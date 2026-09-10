import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

test.slow()

test("renders the seeded planning chat history on load", async ({ page }) => {
  await signInAsDemo(page)

  await page.getByRole("link", { name: "Preview walkthrough" }).click()

  const stream = page.getByTestId("chat-message-stream")
  await expect(stream).toContainText("Show me what is happening in this preview.")
  await expect(stream).toContainText("This preview is seeded with a small demo repository, one epic, and representative jobs so the dashboard is not empty.")
})

test("starts a new planning chat, sends a message, and updates the chat list", async ({ page }) => {
  await signInAsDemo(page)

  await page.getByRole("button", { name: "New Chat" }).click()
  await expect(page).toHaveURL(/\/chats\/\d+$/)
  const chatPath = new URL(page.url()).pathname
  const chatLink = page.locator(`a[href="${chatPath}"]`)
  await expect(page.getByTestId("chat-message-stream")).toContainText("Start a chat with this repository.")
  await expect(chatLink).toBeVisible()

  const message = `E2E planning chat message ${Date.now()}`
  await page.getByPlaceholder(/ask about this repository|ask anything/i).fill(message)
  await page.getByRole("button", { name: "Send message" }).click()

  await expect(page.getByTestId("chat-message-stream")).toContainText(message)
  await expect(chatLink).toBeVisible()
})
