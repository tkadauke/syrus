import { mkdirSync } from "node:fs"
import { execFileSync } from "node:child_process"
import path from "node:path"
import { test, expect, type Locator, type Page } from "@playwright/test"
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
  prepareMobileChromeFixture()
  await page.setViewportSize({ width: 390, height: 844 })
  await signInAsDemo(page)
  await setMobileChatAutoHide(page, true)
  await page.reload()
  expect(await mobileChatAutoHideBootstrapValue(page)).toBe(true)

  try {
    await page.getByRole("button", { name: "Open sidebar" }).click()
    const previewChatPath = await page.getByRole("link", { name: "Preview walkthrough" }).getAttribute("href")
    expect(previewChatPath).toBeTruthy()
    await page.goto(previewChatPath!)

    const stream = page.getByTestId("chat-message-stream")
    const message = page.locator("article[id^='chat_message_']").first()
    await expect(stream).toContainText("Mobile chrome fixture line 1")
    await expect(message).toBeVisible()

    const visible = await mobileChatGeometry(page)
    expect(visible.chromeBottom).toBeGreaterThan(100)
    expect(visible.streamTop).toBeGreaterThanOrEqual(visible.chromeBottom - 2)
    await captureMobileChromeScreenshot(page, "chat-visible")

    await scrollMobileChatStream(stream, 320)
    await expect(page.getByTestId("mobile-chat-hidden-header-sidebar-button")).toBeVisible()
    await expect(page.getByTestId("mobile-app-header")).toHaveCSS("opacity", "0")

    const hidden = await mobileChatGeometry(page)
    expect(visible.streamTop - hidden.streamTop).toBeGreaterThan(100)
    expect(hidden.streamTop).toBeLessThanOrEqual(1)
    expect(hidden.streamBottom).toBeGreaterThanOrEqual(hidden.viewportHeight - 1)
    expect(hidden.firstContentTop - hidden.streamTop).toBeLessThanOrEqual(8)
    await captureMobileChromeScreenshot(page, "chat-hidden")

    await stream.click({ position: { x: 8, y: 8 } })
    await expect(page.getByTestId("mobile-app-header")).toHaveCSS("opacity", "1")
    await page.getByRole("navigation", { name: "Chat mobile tabs" }).getByRole("button", { name: "Files" }).click()
    await expect(page.getByRole("complementary", { name: "Chat workspace" })).toBeVisible()
    await expect(page.getByTestId("coding-files-panel")).toBeVisible()
    await expect(page.getByTestId("coding-files-panel")).not.toContainText(/checkout.*not.*ready|Coding checkout/i)
    await expect(page.getByRole("button", { name: "README.md" })).toBeVisible()
    await page.getByRole("button", { name: "README.md" }).click()
    await expect(page.getByText("# Mobile chrome fixture")).toBeVisible()

    const files = await mobileFilesGeometry(page)
    expect(files.chromeBottom).toBeGreaterThan(100)
    expect(files.workspaceTop).toBeGreaterThanOrEqual(files.chromeBottom - 2)
    expect(files.workspaceHeight).toBeGreaterThan(500)
    expect(files.panelHeight).toBeGreaterThan(440)
    expect(files.filesSplitHeight).toBeGreaterThan(360)
    expect(files.filesSplitTop - files.workspaceTop).toBeLessThan(120)
    await captureMobileChromeScreenshot(page, "files-visible")
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

async function mobileChatAutoHideBootstrapValue(page: Page) {
  return page.evaluate(() => {
    const script = document.getElementById("syrus-bootstrap-data")
    if (!script?.textContent) return null
    return JSON.parse(script.textContent).current_user?.mobile_chat_auto_hide_header ?? null
  })
}

async function scrollMobileChatStream(stream: Locator, delta: number) {
  await stream.evaluate((element) => element.scrollTo(0, 0))
  const box = await stream.boundingBox()
  if (!box) throw new Error("Missing chat stream box")
  await stream.page().mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await stream.page().mouse.wheel(0, delta)
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
    const firstContent = document.querySelector<HTMLElement>("[data-testid='chat-message-stream'] article")
    if (!firstContent) throw new Error("Missing first chat stream content")

    return {
      chromeBottom: Math.max(header.bottom, tabs.bottom),
      firstContentTop: firstContent.getBoundingClientRect().top,
      streamBottom: stream.bottom,
      streamTop: stream.top,
      viewportHeight: window.innerHeight
    }
  })
}

async function mobileFilesGeometry(page: Page) {
  return page.evaluate(() => {
    const rectFor = (selector: string) => {
      const element = document.querySelector<HTMLElement>(selector)
      if (!element) throw new Error(`Missing ${selector}`)
      return element.getBoundingClientRect()
    }
    const header = rectFor("[data-testid='mobile-app-header']")
    const tabs = rectFor("[data-testid='mobile-chat-tabs-shell']")
    const workspace = rectFor("[aria-label='Chat workspace']")
    const panel = rectFor("[data-testid='coding-files-panel']")
    const filesSplit = rectFor("[data-testid='coding-files-split']")

    return {
      chromeBottom: Math.max(header.bottom, tabs.bottom),
      filesSplitHeight: filesSplit.height,
      filesSplitTop: filesSplit.top,
      panelHeight: panel.height,
      workspaceHeight: workspace.height,
      workspaceTop: workspace.top
    }
  })
}

async function captureMobileChromeScreenshot(page: Page, name: "chat-visible" | "chat-hidden" | "files-visible") {
  const artifactDir = path.join(process.cwd(), "tmp", "mobile-chrome-e2e")
  mkdirSync(artifactDir, { recursive: true })
  await page.screenshot({ fullPage: false, path: path.join(artifactDir, `${name}.png`) })
}

function prepareMobileChromeFixture() {
  execFileSync(
    "bin/rails",
    [
      "runner",
      `
      user = User.find_by!(email_address: "demo@syrus.local")
      user.mobile_chat_auto_hide_header = false
      user.claude_oauth_token = "local-e2e-token"
      user.agent_provider = "claude"
      user.chat_provider = "claude"
      user.save!

      repository = Repository.find_by!(owner: "demo", name: "syrus-preview")
      chat = ChatSession.find_by!(user: user, title: "Preview walkthrough")
      chat.update!(chat_provider: "claude")
      if chat.messages.where("content LIKE ?", "%Mobile chrome fixture line%").count < 16
        16.times do |index|
          ChatMessage.create!(
            chat_session: chat,
            role: "assistant",
            content: { "text" => "Mobile chrome fixture line #{index + 1}: enough content to make the mobile message stream scroll." }
          )
        end
      end
      epic = Epic.find_or_initialize_by(repository: repository, title: "Preview the operator workflow")
      epic.assign_attributes(user: user, owner_user: user, state: "done", done_at: Time.current, epic_dependency_policy: "linear")
      epic.save!
    `
    ],
    { stdio: "ignore" }
  )
}
