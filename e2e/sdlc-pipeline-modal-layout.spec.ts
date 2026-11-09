import { expect, test, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// Embedded (modal) SDLC Pipeline: the canvas and history rail share the full inner height, and a
// seven-day rail scrolls independently instead of compressing its events. The pipeline API is
// mocked so the geometry does not depend on seeded repository data.

test.skip(Boolean(process.env.E2E_BASE_URL), "Mocks the pipeline API on the local app server.")

const NOW = Date.parse("2026-10-31T12:00:00Z")
const HOUR = 3_600_000
const ticks = Array.from({ length: 30 }, (_, i) => new Date(NOW - (i * 5 + 1) * HOUR).toISOString()).reverse()
const stage = {
  key: "review",
  label: "Review",
  kind: "lifecycle",
  total: 0,
  attention_count: 0,
  aging_count: 0,
  oldest_age_seconds: null,
  highlighted_items: []
}
const body = {
  repository: { id: 1, slug: "acme/widgets" },
  generated_at: new Date(NOW).toISOString(),
  evidence: { status: "complete", incomplete_count: 0 },
  tabs: [],
  groups: [],
  stages: [stage],
  filter: { and: [{ field: "associated_chat_id", op: "is", value: 8 }] },
  filter_schema: [{ field: "associated_chat_id", label: "Chat", bucket: "number", operators: ["is"] }],
  active_smart_folder_id: null,
  smart_folders: [],
  history: {
    from: new Date(NOW - 7 * 24 * HOUR).toISOString(),
    to: new Date(NOW).toISOString(),
    checkpoint: { at: new Date(NOW - 7 * 24 * HOUR).toISOString(), placements: [] },
    deltas: [],
    ticks,
    traces: [],
    accuracy: { status: "reconstructed", truncated: false, message: "" }
  }
}

async function open(page: Page, viewport: { width: number; height: number }) {
  await page.setViewportSize(viewport)
  await page.route("**/api/v1/app/repositories/1/sdlc_pipeline*", (route) => route.fulfill({ json: body }))
  await signInAsDemo(page)
  await page.goto("/repositories/1/plugin/sdlc-pipeline?syrus_presentation=embedded&q=chat-filter")
  await expect(page.getByRole("region", { name: "Pipeline stages" })).toBeVisible()
}

for (const viewport of [
  { name: "large desktop", width: 1728, height: 931 },
  { name: "narrow mobile", width: 390, height: 780 }
]) {
  test(`fills the height and keeps a scrollable rail at ${viewport.name}`, async ({ page }) => {
    await open(page, viewport)
    const main = page.getByTestId("embedded-pipeline-view")
    const canvas = page.getByTestId("pipeline-with-time-rail")
    const rail = page.getByTestId("history-rail-scroll")
    const column = page.locator('[data-stage="review"]')

    const [mainBox, canvasBox, railBox, columnBox] = await Promise.all([main.boundingBox(), canvas.boundingBox(), rail.boundingBox(), column.boundingBox()])
    // 1 + 2: the canvas reaches the bottom edge and the rail shares its height; no blank region below the stage.
    expect(canvasBox!.y + canvasBox!.height).toBeGreaterThan(mainBox!.y + mainBox!.height - 2)
    expect(railBox!.height).toBeGreaterThan(canvasBox!.height * 0.6)
    expect(columnBox!.height).toBeGreaterThan(canvasBox!.height * 0.7)

    // 3 + 4: seven days scroll rather than compress; ticks stay separate and several labels exist.
    const metrics = await rail.evaluate((node) => ({ scroll: node.scrollHeight, client: node.clientHeight }))
    expect(metrics.scroll).toBeGreaterThan(metrics.client * 2)
    expect(await page.getByTestId("history-rail-label").count()).toBeGreaterThan(6)
    const tops = await rail.locator("button[data-event-kind]").evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().top))
    for (let i = 1; i < tops.length; i++) expect(Math.abs(tops[i] - tops[i - 1])).toBeGreaterThanOrEqual(13)
    await page.screenshot({ path: test.info().outputPath(`pipeline-modal-${viewport.name.replace(" ", "-")}.png`) })
  })
}

test("moving the cursor keeps filters intact and scrolls only the rail", async ({ page }) => {
  await open(page, { width: 1728, height: 931 })
  const stages = page.getByRole("region", { name: "Pipeline stages" })
  const before = await stages.evaluate((node) => node.scrollLeft)
  await page.getByRole("button", { name: "Previous event" }).click()
  await expect(page.getByTestId("selected-history-time").or(page.getByText(/Oct 31|10\/31/).first())).toBeVisible()
  await expect(page.getByRole("button", { name: "Chat is 8" })).toBeVisible()
  expect(page.url()).toContain("at=")
  expect(await stages.evaluate((node) => node.scrollLeft)).toBe(before)
  await expect(page.getByTestId("history-rail-cursor")).toBeInViewport()
})
