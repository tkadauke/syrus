import { expect, test } from "@playwright/test"
import { readFileSync } from "node:fs"

const chatCss = readFileSync("app/assets/tailwind/application.css", "utf8")

test.describe("chat markdown table layout", () => {
  test("fits ordinary breakable three-column tables in a 402px viewport", async ({ page }) => {
    await page.setViewportSize({ width: 402, height: 844 })
    await page.setContent(`
      <style>
        ${chatCss}
        body { margin: 0; font-family: system-ui, sans-serif; }
        .message { box-sizing: border-box; width: calc(100vw - 32px); margin: 16px; }
      </style>
      <div class="message">
        <div class="chat-prose">
          <div class="chat-prose-table-wrap" data-testid="wrap">
            <table class="chat-prose-table chat-prose-table--balanced">
              <colgroup>
                <col class="chat-prose-table__col chat-prose-table__col--compact" data-chat-table-column="compact" style="--chat-table-column-width: 11.3%;">
                <col class="chat-prose-table__col chat-prose-table__col--label" data-chat-table-column="label" style="--chat-table-column-width: 28.8%;">
                <col class="chat-prose-table__col chat-prose-table__col--prose" data-chat-table-column="prose" style="--chat-table-column-width: 60%;">
              </colgroup>
              <thead>
                <tr><th>#</th><th>Section</th><th>Status</th></tr>
              </thead>
              <tbody>
                <tr><td>1</td><td>Dashboard</td><td>The run summary wraps as ordinary prose and remains readable on mobile.</td></tr>
                <tr><td>2</td><td>Review</td><td>Final status details stay in the last column instead of being pushed off screen.</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    `)

    const wrap = page.getByTestId("wrap")
    const statusCell = page.getByRole("cell", { name: /Final status details/ })

    await expect(wrap).toBeVisible()
    await expect.poll(async () => wrap.evaluate((element) => element.scrollWidth - element.clientWidth)).toBeLessThanOrEqual(1)

    const [wrapBox, statusBox] = await Promise.all([wrap.boundingBox(), statusCell.boundingBox()])
    expect(wrapBox).not.toBeNull()
    expect(statusBox).not.toBeNull()
    expect(statusBox!.x + statusBox!.width).toBeLessThanOrEqual(wrapBox!.x + wrapBox!.width + 1)
  })

  test("keeps genuinely wide unbreakable tables horizontally scrollable", async ({ page }) => {
    await page.setViewportSize({ width: 402, height: 844 })
    await page.setContent(`
      <style>
        ${chatCss}
        body { margin: 0; font-family: system-ui, sans-serif; }
        .message { box-sizing: border-box; width: calc(100vw - 32px); margin: 16px; }
      </style>
      <div class="message">
        <div class="chat-prose">
          <div class="chat-prose-table-wrap" data-testid="wrap">
            <table class="chat-prose-table chat-prose-table--wide">
              <colgroup>
                <col class="chat-prose-table__col chat-prose-table__col--label" data-chat-table-column="label" style="--chat-table-column-width: 32.4%;">
                <col class="chat-prose-table__col chat-prose-table__col--prose" data-chat-table-column="prose" style="--chat-table-column-width: 67.6%;">
              </colgroup>
              <thead>
                <tr><th>Label</th><th>Value</th></tr>
              </thead>
              <tbody>
                <tr><td>Artifact</td><td>https://example.test/downloads/ALongUnbrokenTokenThatCannotWrapNaturally</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    `)

    const wrap = page.getByTestId("wrap")

    await expect(wrap).toBeVisible()
    await expect.poll(async () => wrap.evaluate((element) => element.scrollWidth - element.clientWidth)).toBeGreaterThan(1)
  })
})
