import { test, expect } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Chat platform golden path (planning mode): starting a new chat, sending a
// message, and confirming it renders in the message stream. No bin/jobs
// worker process runs against this preview server (same constraint as
// dashboard.spec.ts's bulk-retry test), so a sent message never gets a real
// agent reply -- these assertions stay scoped to what the UI does
// synchronously off the message-create response itself: the new chat
// joining the sidebar's recent-chats list, and the message appearing in the
// stream. Never wait on an actual agent turn.
test("starts a new chat, sends a message, and renders it in the message stream", async ({ page }) => {
  await signInAsDemo(page)

  await page.getByRole("button", { name: "New Chat", exact: true }).click()
  await page.waitForURL(/\/chats\/\d+$/)

  const chatId = page.url().match(/\/chats\/(\d+)$/)?.[1]
  if (!chatId) throw new Error(`Expected a numeric chat id in the URL, got ${page.url()}`)

  // The new chat joins the sidebar's recent-chats list synchronously off the
  // chat-creation response (see updateRecentChatCache in AppChromeV2.tsx's
  // startChat), before any message is sent.
  const recentChats = page.getByRole("navigation", { name: "Recent chats" })
  await expect(recentChats.locator(`a[href="/chats/${chatId}"]`)).toBeVisible()

  // Scope to the message composer's own wrapper (data-tour="chat-compose")
  // rather than a bare textbox/button role query -- the sidebar's own search
  // field is a textbox too, and is always present alongside the chat page.
  const composer = page.locator('[data-tour="chat-compose"]')
  const messageText = `E2E golden path message ${Date.now()}`
  await composer.getByRole("textbox").fill(messageText)

  const messageSent = page.waitForResponse((response) =>
    response.url().includes(`/api/v1/app/chats/${chatId}/message`) && response.request().method() === "POST" && response.ok()
  )
  await composer.getByRole("button", { name: "Send message" }).click()
  await messageSent

  await expect(page.getByTestId("chat-message-stream").getByText(messageText)).toBeVisible()
})

// Uses the seeded "Preview walkthrough" chat (db/seeds.rb) as a fixture for
// history-on-load: it already carries two messages, so this only needs to
// confirm the existing thread renders correctly, not send anything new.
test("renders the seeded Preview walkthrough chat's message history on load", async ({ page }) => {
  await signInAsDemo(page)

  await page.getByRole("navigation", { name: "Recent chats" }).getByRole("link", { name: "Preview walkthrough", exact: true }).click()
  await expect(page).toHaveURL(/\/chats\/\d+$/)

  const messageStream = page.getByTestId("chat-message-stream")
  await expect(messageStream.getByText("Show me what is happening in this preview.")).toBeVisible()
  await expect(messageStream.getByText("This preview is seeded with a small demo repository, one epic, and representative jobs so the dashboard is not empty.")).toBeVisible()
})
