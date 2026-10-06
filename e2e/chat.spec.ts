import { test, expect, type Page } from "@playwright/test"
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

test("mobile hidden chat chrome reclaims the rendered message region", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await signInAsDemo(page)
  await setMobileChatAutoHide(page, true)
  await page.reload()

  try {
    await page.getByRole("button", { name: "Open sidebar" }).click()
    await page.getByRole("link", { name: "Preview walkthrough" }).click()

    const stream = page.getByTestId("chat-message-stream")
    const message = page.locator("article[id^='chat_message_']").first()
    await expect(stream).toContainText("Show me what is happening in this preview.")
    await expect(message).toBeVisible()

    const visible = await mobileChatGeometry(page)
    expect(visible.chromeBottom).toBeGreaterThan(100)
    expect(visible.streamTop).toBeGreaterThanOrEqual(visible.chromeBottom - 2)

    await stream.dispatchEvent("click")
    await expect(page.getByTestId("mobile-chat-hidden-header-sidebar-button")).toBeVisible()
    await expect(page.getByTestId("mobile-app-header")).toHaveCSS("opacity", "0")

    const hidden = await mobileChatGeometry(page)
    const reclaimed = visible.streamTop - hidden.streamTop
    expect(reclaimed).toBeGreaterThan(100)
    expect(hidden.streamTop).toBeLessThanOrEqual(24)
    expect(hidden.firstContentTop - hidden.streamTop).toBeLessThan(48)
  } finally {
    await setMobileChatAutoHide(page, false)
  }
})

async function setMobileChatAutoHide(page: Page, enabled: boolean) {
  await page.evaluate(async (mobileChatAutoHideHeader) => {
    const csrf = document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content
    const response = await fetch("/api/v1/app/credentials", {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        ...(csrf ? { "X-CSRF-Token": csrf } : {})
      },
      body: JSON.stringify({ user: { mobile_chat_auto_hide_header: mobileChatAutoHideHeader } })
    })
    if (!response.ok) throw new Error(`Could not update mobile auto-hide: ${response.status}`)
  }, enabled)
}

async function mobileChatGeometry(page: Page) {
  return page.evaluate(() => {
    const rectFor = (selector: string) => {
      const element = document.querySelector<HTMLElement>(selector)
      if (!element) throw new Error(`Missing ${selector}`)
      return element.getBoundingClientRect()
    }
    const header = rectFor("[data-testid='mobile-app-header']")
    const tabs = rectFor("[data-testid='mobile-chat-tabs-shell']")
    const stream = rectFor("[data-testid='chat-message-stream']")
    const firstContent = stream.firstElementChild
    if (!(firstContent instanceof HTMLElement)) throw new Error("Missing first chat stream content")

    return {
      chromeBottom: Math.max(header.bottom, tabs.bottom),
      firstContentTop: firstContent.getBoundingClientRect().top,
      streamTop: stream.top
    }
  })
}
