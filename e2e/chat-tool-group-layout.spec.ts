import { expect, test, type Locator, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { signInAsDemo } from "./support/auth"

test.slow()
test.skip(Boolean(process.env.E2E_BASE_URL), "Seeds local chat tool-call fixtures before opening the chat route.")

const LONG_TOOL_NAME = "InspectUnusuallyLongRepositorySourceNamesWithoutOverflowingTheChatColumn"

let chatPath: string

test.beforeAll(() => {
  chatPath = seedToolGroupFixture()
})

test("keeps the grouped Read summary readable beside its metadata at 1728x931", async ({ page }) => {
  await openFixture(page, { width: 1728, height: 931 })

  const label = page.getByText("Inspected 9 sources", { exact: true })
  const summary = label.locator("xpath=ancestor::summary")
  const detail = summary.locator(":scope > span").nth(4)

  await expect(label).toBeVisible()
  await expect(summary.getByText("Done", { exact: true })).toBeVisible()
  await expect(summary.getByText("9", { exact: true })).toBeVisible()
  await expect(detail).toBeVisible()

  const labelBox = await label.boundingBox()
  expect(labelBox).not.toBeNull()
  expect(labelBox!.height).toBeLessThan(30)
  expect(labelBox!.width).toBeGreaterThan(100)
  await expect(detail).toHaveCSS("text-overflow", "ellipsis")
  await expectNoHorizontalOverflow(page, summary)
})

test("keeps collapsed summaries to one prioritized line on mobile without overflowing", async ({ page }) => {
  await openFixture(page, { width: 402, height: 812 })

  for (const text of ["Inspected 9 sources", "Admin version", "Bash"]) {
    const label = page.getByText(text, { exact: true })
    const summary = label.locator("xpath=ancestor::summary")

    await expect(label).toBeVisible()
    await expect(summary.getByText("Done", { exact: true })).toBeVisible()
    const summaryBox = await summary.boundingBox()
    expect(summaryBox).not.toBeNull()
    expect(summaryBox!.height).toBeLessThanOrEqual(28)
    await expectNoHorizontalOverflow(page, summary)
  }

  const longLabel = page.getByText(`${LONG_TOOL_NAME} (2)`, { exact: true })
  const longSummary = longLabel.locator("xpath=ancestor::summary")

  await expect(longLabel).toBeVisible()
  await expect(longLabel).toHaveAttribute("title", `${LONG_TOOL_NAME} (2)`)
  await expect(longLabel).toHaveCSS("text-overflow", "ellipsis")
  await expect(longSummary.getByText("Done", { exact: true })).toBeVisible()
  await expect(longSummary.getByText("2", { exact: true })).toBeVisible()
  const summaryBox = await longSummary.boundingBox()
  expect(summaryBox).not.toBeNull()
  expect(summaryBox!.height).toBeLessThanOrEqual(28)
  await expectNoHorizontalOverflow(page, longSummary)
})

async function openFixture(page: Page, viewport: { width: number; height: number }) {
  await page.setViewportSize(viewport)
  await signInAsDemo(page)
  await page.goto(chatPath)
  await expect(page.getByTestId("chat-message-stream")).toContainText("Tool group layout fixture.")
}

function seedToolGroupFixture() {
  if (process.env.E2E_BASE_URL) throw new Error("The tool-group layout fixture requires the local test database.")

  return execFileSync(
    "bin/rails",
    [
      "runner",
      `
    user = User.find_by!(email_address: "demo@syrus.local")
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")
    chat = ChatSession.find_or_initialize_by(user: user, title: "Tool group layout fixture")
    chat.assign_attributes(repository: repository, mode: "planning", pinned: true, last_message_at: Time.current)
    chat.save!
    chat.messages.destroy_all

    chat.messages.create!(role: "assistant", content: { "text" => "Tool group layout fixture." })

    9.times do |index|
      tool_use_id = "layout-read-#{index}"
      path = "app/services/example_source_with_a_descriptive_name_#{index}.rb"
      chat.messages.create!(
        role: "tool_use",
        tool_name: "Read",
        tool_use_id: tool_use_id,
        content: { "type" => "tool_use", "id" => tool_use_id, "name" => "Read", "input" => { "file_path" => path } }
      )
      chat.messages.create!(
        role: "tool_result",
        tool_name: "Read",
        tool_use_id: tool_use_id,
        content: { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "class ExampleSource#{index}; end", "is_error" => false }
      )
    end

    2.times do |index|
      tool_use_id = "layout-long-#{index}"
      chat.messages.create!(
        role: "tool_use",
        tool_name: ${JSON.stringify(LONG_TOOL_NAME)},
        tool_use_id: tool_use_id,
        content: { "type" => "tool_use", "id" => tool_use_id, "name" => ${JSON.stringify(LONG_TOOL_NAME)}, "input" => { "source" => "a-very-long-source-name-#{index}" } }
      )
      chat.messages.create!(
        role: "tool_result",
        tool_name: ${JSON.stringify(LONG_TOOL_NAME)},
        tool_use_id: tool_use_id,
        content: { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "inspected source #{index}", "is_error" => false }
      )
    end

    { "admin_version" => "Admin version", "Bash" => "Bash" }.each do |tool_name, label|
      tool_use_id = "layout-#{tool_name}"
      chat.messages.create!(
        role: "tool_use",
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: { "type" => "tool_use", "id" => tool_use_id, "name" => tool_name, "input" => { "command" => "a deliberately long argument that must not wrap" } }
      )
      chat.messages.create!(
        role: "tool_result",
        tool_name: tool_name,
        tool_use_id: tool_use_id,
        content: { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "#{label} completed with a deliberately long result summary", "is_error" => false }
      )
    end

    chat.messages.create!(role: "assistant", content: { "text" => "Fixture complete." })
    puts "/chats/#{chat.id}"
  `
    ],
    { env: process.env }
  )
    .toString()
    .trim()
}

async function expectNoHorizontalOverflow(page: Page, summary: Locator) {
  const measurements = await page.evaluate(() => ({
    html: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    body: document.body.scrollWidth - document.body.clientWidth
  }))
  expect(measurements.html).toBeLessThanOrEqual(1)
  expect(measurements.body).toBeLessThanOrEqual(1)
  await expect.poll(async () => summary.evaluate((element) => element.scrollWidth - element.clientWidth)).toBeLessThanOrEqual(1)
}
