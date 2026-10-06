import { expect, test, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { mkdirSync } from "node:fs"
import path from "node:path"
import { signInAsDemo } from "./support/auth"

test.slow()
test.skip(Boolean(process.env.E2E_BASE_URL), "Seeds a local long-title proposal fixture before opening the chat route.")

const LONG_TITLE = "HAWebhookNowPlayingUpdatesPlaybackStateBrowserDeepLinkToSpecificIntegrationSurfaceWithoutNaturalBreaks"
const SCREENSHOT_DIR = path.join(process.cwd(), "tmp", "visual-review")

let chatPath: string

test.beforeAll(() => {
  chatPath = seedProposalOverflowFixture()
  mkdirSync(SCREENSHOT_DIR, { recursive: true })
})

for (const viewport of [
  { name: "mobile", width: 402, height: 812 },
  { name: "desktop", width: 1280, height: 720 }
] as const) {
  test(`renders the proposal card without horizontal overflow on ${viewport.name}`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height })
    await signInAsDemo(page)
    await page.goto(chatPath)

    await expect(page).not.toHaveURL(/\/session\/new$/)
    await expect(page.getByTestId("chat-message-stream")).toContainText("Proposal overflow fixture.")
    await expect(page.getByRole("heading", { name: LONG_TITLE })).toBeVisible()

    await expectNoHorizontalOverflow(page)

    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, `proposal-overflow-${viewport.name}.png`),
      fullPage: false
    })
  })
}

function seedProposalOverflowFixture() {
  if (process.env.E2E_BASE_URL) {
    throw new Error("The proposal overflow E2E fixture can only be created against the local test database.")
  }

  return execFileSync("bin/rails", ["runner", `
    user = User.find_by!(email_address: "demo@syrus.local")
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")
    chat = ChatSession.find_or_initialize_by(user: user, title: "Proposal overflow fixture")
    chat.assign_attributes(
      repository: repository,
      mode: "planning",
      pinned: true,
      last_message_at: Time.current
    )
    chat.save!

    chat.messages.where("content LIKE ?", "%Proposal overflow fixture.%").destroy_all
    chat.proposals.where(slug: "job-proposal-overflow-fixture").destroy_all

    proposal = chat.proposals.create!(
      repository: repository,
      slug: "job-proposal-overflow-fixture",
      title: ${JSON.stringify(LONG_TITLE)},
      body: "Regression fixture for a long proposal title inside the chat stream.",
      kind: "job",
      provider_setting: "default",
      route_to_backlog: true
    )

    chat.messages.create!(
      role: "assistant",
      proposal: proposal,
      content: { "text" => "Proposal overflow fixture." }
    )

    puts "/chats/#{chat.id}"
  `], { env: process.env }).toString().trim()
}

async function expectNoHorizontalOverflow(page: Page) {
  const measurements = await page.evaluate(() => {
    const stream = document.querySelector<HTMLElement>("[data-testid='chat-message-stream']")
    return {
      htmlOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      bodyOverflow: document.body.scrollWidth - document.body.clientWidth,
      streamOverflow: stream ? stream.scrollWidth - stream.clientWidth : Number.NaN
    }
  })

  expect(measurements.htmlOverflow).toBeLessThanOrEqual(1)
  expect(measurements.bodyOverflow).toBeLessThanOrEqual(1)
  expect(measurements.streamOverflow).toBeLessThanOrEqual(1)
}
