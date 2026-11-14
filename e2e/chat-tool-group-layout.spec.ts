// OPERATOR DESIGN LOCK — DO NOT REMOVE, WEAKEN, REWRITE, OR UPDATE THESE
// ASSERTIONS/FIXTURES TO PERMIT A MULTI-LINE COLLAPSED TOOL CARD WITHOUT
// EXPLICIT WRITTEN APPROVAL FROM THOMAS KADAUKE. A collapsed tool card is
// exactly one visual line at every width: title without a line break, then
// pills, then a clipped/ellipsized details preview. Full details belong only
// in the expanded state.
import { expect, test, type Locator, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { signInAsDemo } from "./support/auth"

test.slow()
test.skip(Boolean(process.env.E2E_BASE_URL), "Seeds local chat tool-call fixtures before opening the chat route.")

const LONG_TOOL_NAME = "InspectUnusuallyLongRepositorySourceNamesWithoutOverflowingTheChatColumn"
const MULTILINE_BASH_COMMAND =
  '/bin/bash -lc \'rg -n "Visual evidence|No screenshots captured" app spec\n  && sed -n "1,220p" app/frontend/routes/jobDetail/ReviewWorkspace.tsx\''

let chatPath: string

test.beforeAll(() => {
  chatPath = seedToolGroupFixture()
})

for (const viewport of [
  { name: "narrow phone", width: 320, height: 700 },
  { name: "mobile", width: 402, height: 812 },
  { name: "tablet", width: 768, height: 900 },
  { name: "desktop", width: 1728, height: 931 }
]) {
  test(`locks every collapsed header to one exact row at ${viewport.name} width`, async ({ page }) => {
    await openFixture(page, viewport)

    for (const text of ["Inspected 9 sources", "Admin version", "Bash", `${LONG_TOOL_NAME} (2)`]) {
      const title = page.getByText(text, { exact: true })
      const summary = title.locator("xpath=ancestor::summary")
      const preview = summary.getByTestId("tool-group-preview")
      const pills = summary.locator(":scope > span.inline-flex")

      await expect(title).toBeVisible()
      await expect(summary).toHaveCSS("display", "flex")
      await expect(summary).toHaveCSS("white-space", "nowrap")
      await expect(title).toHaveCSS("text-overflow", "ellipsis")
      await expect(preview).toHaveCSS("text-overflow", "ellipsis")
      await expectOneComputedLine(summary)
      await expectSameOrderedRow(summary.locator(":scope > span"))
      expect(await pills.count()).toBe(text.includes("(2)") || text.includes("9") ? 2 : 1)
      await expectNoHorizontalOverflow(page, summary)
    }

    const bashTitle = page.getByText("Bash", { exact: true })
    const bashSummary = bashTitle.locator("xpath=ancestor::summary")
    await expect(bashSummary.getByText("Running", { exact: true })).toBeVisible()
    await expect(bashSummary.getByTestId("tool-group-preview")).toBeEmpty()
    await bashSummary.click()
    const expandedCalls = bashSummary.locator("xpath=following-sibling::div[1]")
    await expect(expandedCalls).not.toContainText(MULTILINE_BASH_COMMAND)
    await expandedCalls.getByText("Raw details", { exact: false }).click()
    const rawDetails = expandedCalls.locator("code")
    await expect(rawDetails).toBeVisible()
    const parsedDetails = JSON.parse(await rawDetails.innerText())
    expect(parsedDetails.input.command).toBe(MULTILINE_BASH_COMMAND)
    await expectNoHorizontalOverflow(page, bashSummary)
  })
}

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

    { "admin_version" => "Admin version" }.each do |tool_name, label|
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


    bash_tool_use_id = "layout-running-bash"
    chat.messages.create!(
      role: "tool_use",
      tool_name: "Bash",
      tool_use_id: bash_tool_use_id,
      content: { "type" => "tool_use", "id" => bash_tool_use_id, "name" => "Bash", "input" => { "command" => ${JSON.stringify(MULTILINE_BASH_COMMAND)} } }
    )

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

async function expectOneComputedLine(summary: Locator) {
  const geometry = await summary.evaluate((element) => {
    const style = getComputedStyle(element)
    return {
      actual: element.getBoundingClientRect().height,
      expected: Number.parseFloat(style.lineHeight) + Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom)
    }
  })
  expect(Math.abs(geometry.actual - geometry.expected)).toBeLessThanOrEqual(0.5)
}

async function expectSameOrderedRow(children: Locator) {
  const boxes = await children.evaluateAll((elements) =>
    elements.map((element) => {
      const box = element.getBoundingClientRect()
      return { left: box.left, right: box.right, top: box.top, bottom: box.bottom }
    })
  )
  expect(boxes.length).toBeGreaterThanOrEqual(4)
  for (let index = 1; index < boxes.length; index += 1) {
    expect(boxes[index].left).toBeGreaterThanOrEqual(boxes[index - 1].right - 0.5)
    expect(boxes[index].top).toBeLessThan(boxes[index - 1].bottom)
    expect(boxes[index].bottom).toBeGreaterThan(boxes[index - 1].top)
  }
}
