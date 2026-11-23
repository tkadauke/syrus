import { writeFileSync } from "node:fs"
import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test"
import { signInAsDemo, waitForSpaBoot } from "./support/auth"
import { jobsListRow } from "./support/dashboard"

// Bug-report screenshots hollow opted-in rows outside the viewport (see
// app/frontend/lib/screenshotCapture.ts) so html2canvas skips work for content
// it would crop away anyway. That is only acceptable if it changes nothing you
// can see: every scenario here captures the same viewport with hollowing off
// and on and requires the two canvases to be identical, pixel for pixel.
//
// Both captures come from the same renderer at the same moment, so exact
// equality is achievable; a native browser screenshot would not be comparable,
// since html2canvas never matches it exactly.

test.slow()

const FILES = 6
const LINES_PER_FILE = 400

type ParityResult = {
  width: number
  height: number
  hollowWidth: number
  hollowHeight: number
  differingPixels: number
  diffBox?: { left: number; top: number; right: number; bottom: number }
  hollowed: number
  candidates: number
  fullMs: number
  hollowMs: number
  fullPng?: string
  hollowPng?: string
}

function syntheticPatch(fileIndex: number) {
  const lines = [
    `diff --git a/app/frontend/generated/module_${fileIndex}.ts b/app/frontend/generated/module_${fileIndex}.ts`,
    `--- a/app/frontend/generated/module_${fileIndex}.ts`,
    `+++ b/app/frontend/generated/module_${fileIndex}.ts`,
    `@@ -1,${LINES_PER_FILE} +1,${LINES_PER_FILE} @@ export function module${fileIndex}() {`
  ]
  for (let line = 0; line < LINES_PER_FILE; line++) {
    const prefix = line % 7 === 0 ? "-" : line % 5 === 0 ? "+" : " "
    lines.push(`${prefix}  const value_${line} = compute(${line}, "label ${line}", { retries: ${line % 4}, enabled: true }) // note ${line}`)
  }
  return lines.join("\n")
}

async function stubLargeReviewDiff(page: Page) {
  await page.route((url) => /^\/api\/v1\/app\/jobs\/[^/]+\/source_diff$/.test(url.pathname), async (route) => {
    const version = {
      id: 9101, job_id: 1, version_index: 1, base_sha: "base-sha", head_sha: "head-sha", base_ref: "main",
      head_ref: "syrus/large-diff", workflow_id: null, workflow: null, run_id: null, trigger_kind: "initial",
      label: "Version 1", reason: "initial", truncated: false, files_count: FILES, comments_count: 0, metadata: {}, created_at: null
    }
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        job_id: 1, base_ref: "base-sha", head_ref: "head-sha", base_sha: "base-sha", head_sha: "head-sha",
        merge_base_sha: "base-sha", default_ref: "main", branch_commits: [], truncated: false, diff_error: null,
        version, versions: [version],
        files: Array.from({ length: FILES }, (_, index) => ({
          additions: Math.ceil(LINES_PER_FILE / 5), deletions: Math.ceil(LINES_PER_FILE / 7),
          path: `app/frontend/generated/module_${index}.ts`, status: "modified", patch: syntheticPatch(index)
        })),
        coverage_annotations: {},
        review_annotations: { annotations: {}, ranges: {}, panels: [], actions: [], counts: [] }
      })
    })
  })
}

async function openLargeReview(page: Page, viewport: { width: number; height: number }) {
  await page.addInitScript(() => window.localStorage.setItem("syrus.debug.screenshotCapture", "1"))
  await stubLargeReviewDiff(page)
  await signInAsDemo(page)
  // Find the job through the desktop jobs table (narrow layouts render cards),
  // then reopen it at the viewport under test.
  await page.setViewportSize({ width: 1440, height: 900 })
  const title = "Inspect preview dashboard states"
  const row = await jobsListRow(page, title)
  await row.getByRole("link", { name: title, exact: true }).click()
  await page.waitForURL(/\/jobs\/[^/?#]+/)
  // The job page finishes settling its own URL once it has loaded; reopening
  // it before then is interrupted under WebKit (see waitForSpaBoot).
  await page.getByRole("button", { name: "Review", exact: true }).waitFor()
  const jobUrl = page.url()
  await page.setViewportSize(viewport)
  await page.goto(jobUrl)
  await waitForSpaBoot(page)
  await page.getByRole("button", { name: "Review", exact: true }).click()
  await expect(page.getByText("app/frontend/generated/module_0.ts").first()).toBeVisible()
  // Large file diffs start collapsed; expand them all so the page is as heavy
  // as a real long review.
  const loadButtons = page.getByRole("button", { name: "Load diff for this file" })
  while ((await loadButtons.count()) > 0) {
    await loadButtons.first().click()
  }
  await expect(page.locator("[data-capture-hollow]").first()).toBeAttached()
  await page.evaluate(() => document.fonts.ready)
}

async function addInnerScrolledSurface(page: Page) {
  const scrollTop = await page.evaluate(() => {
    const surface = document.createElement("section")
    surface.setAttribute("data-testid", "capture-inner-scroll-surface")
    Object.assign(surface.style, {
      height: "280px",
      overflowY: "scroll",
      border: "1px solid rgb(156, 163, 175)",
      background: "white"
    })
    for (let index = 0; index < 1_000; index++) {
      const row = document.createElement("div")
      row.setAttribute("data-capture-hollow", "")
      row.style.height = "24px"
      row.style.whiteSpace = "nowrap"
      row.textContent = `Inner-scrolled diagnostic row ${index}: ${"resource payload ".repeat(4)}`
      surface.appendChild(row)
    }
    document.querySelector("[data-testid='agent-diff-viewer']")?.prepend(surface)
    surface.scrollTop = 12_000
    return surface.scrollTop
  })
  expect(scrollTop, "the synthetic complex surface must be inner-scrolled").toBeGreaterThan(10_000)
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))
}

async function expectContainedBy(locator: Locator, container: Locator) {
  const [box, containerBox] = await Promise.all([locator.boundingBox(), container.boundingBox()])
  expect(box).not.toBeNull()
  expect(containerBox).not.toBeNull()
  expect(box!.x, "content must not be clipped by the dialog's left edge").toBeGreaterThanOrEqual(containerBox!.x)
  expect(box!.x + box!.width, "content must not overflow the dialog's right edge").toBeLessThanOrEqual(containerBox!.x + containerBox!.width)
}

// The element that scrolls the diff vertically: the window, or the nearest
// scrollable ancestor of the viewer.
async function scrollDiffTo(page: Page, fraction: number, extraPx = 0) {
  const scrollTop = await page.evaluate(
    ([fraction, extraPx]) => {
      const viewer = document.querySelector("[data-testid='agent-diff-viewer']") ?? document.body
      let scroller: HTMLElement | null = viewer.parentElement
      while (scroller && !(scroller.scrollHeight > scroller.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(scroller).overflowY))) {
        scroller = scroller.parentElement
      }
      const target = scroller ?? document.scrollingElement!
      target.scrollTop = Math.round((target.scrollHeight - target.clientHeight) * fraction) + extraPx
      return target.scrollTop
    },
    [fraction, extraPx] as const
  )
  // Let the virtualizer render the newly visible files.
  await page.waitForTimeout(400)
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  // A scenario that never scrolled would silently repeat the top-of-page one.
  if (fraction > 0) expect(scrollTop, "the diff must actually scroll").toBeGreaterThan(1000)
}

// Both captures must see the same page. Anything still settling -- syntax
// highlighting, lazily rendered files -- would show up as a difference that has
// nothing to do with hollowing, so wait for a second without DOM mutations.
async function waitForQuietDom(page: Page) {
  await page.evaluate(
    () =>
      new Promise<void>((resolve) => {
        let timer = window.setTimeout(done, 1000)
        const observer = new MutationObserver(() => {
          window.clearTimeout(timer)
          timer = window.setTimeout(done, 1000)
        })
        observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true })
        function done() {
          observer.disconnect()
          resolve()
        }
      })
  )
}

async function compareCaptures(page: Page): Promise<ParityResult> {
  await waitForQuietDom(page)
  return page.evaluate(async () => {
    type Hook = {
      viewport: (options: { hollowOffscreen: boolean }) => Promise<HTMLCanvasElement>
      lastHollowedCount: () => number
      hollowCandidates: () => number
    }
    const hook = (window as unknown as { __syrusScreenshotCapture: Hook }).__syrusScreenshotCapture
    const t0 = performance.now()
    const full = await hook.viewport({ hollowOffscreen: false })
    const t1 = performance.now()
    const hollow = await hook.viewport({ hollowOffscreen: true })
    const t2 = performance.now()
    const a = full.getContext("2d")!.getImageData(0, 0, full.width, full.height).data
    const b = hollow.getContext("2d")!.getImageData(0, 0, hollow.width, hollow.height).data
    let differingPixels = 0
    let diffBox: ParityResult["diffBox"]
    if (a.length === b.length) {
      for (let i = 0; i < a.length; i += 4) {
        if (a[i] !== b[i] || a[i + 1] !== b[i + 1] || a[i + 2] !== b[i + 2] || a[i + 3] !== b[i + 3]) {
          differingPixels++
          const x = (i / 4) % full.width
          const y = Math.floor(i / 4 / full.width)
          diffBox = diffBox
            ? { left: Math.min(diffBox.left, x), top: Math.min(diffBox.top, y), right: Math.max(diffBox.right, x), bottom: Math.max(diffBox.bottom, y) }
            : { left: x, top: y, right: x, bottom: y }
        }
      }
    } else {
      differingPixels = Number.POSITIVE_INFINITY
    }
    const result: ParityResult = {
      width: full.width, height: full.height, hollowWidth: hollow.width, hollowHeight: hollow.height,
      differingPixels, diffBox, hollowed: hook.lastHollowedCount(), candidates: hook.hollowCandidates(),
      fullMs: Math.round(t1 - t0), hollowMs: Math.round(t2 - t1)
    }
    if (differingPixels > 0) {
      result.fullPng = full.toDataURL("image/png")
      result.hollowPng = hollow.toDataURL("image/png")
    }
    return result
  })
}

async function expectPixelParity(page: Page, testInfo: TestInfo, label: string) {
  const result = await compareCaptures(page)
  if (result.fullPng && result.hollowPng) {
    for (const [kind, dataUrl] of [["full", result.fullPng], ["hollow", result.hollowPng]] as const) {
      const path = testInfo.outputPath(`${label}-${kind}.png`)
      writeFileSync(path, Buffer.from(dataUrl.split(",")[1], "base64"))
      await testInfo.attach(`${label}-${kind}.png`, { path, contentType: "image/png" })
    }
  }
  console.log(`[parity] ${label}: ${JSON.stringify({ ...result, fullPng: undefined, hollowPng: undefined })}`)
  expect([result.hollowWidth, result.hollowHeight]).toEqual([result.width, result.height])
  expect(result.differingPixels, `${label}: hollowed capture must match the full capture pixel for pixel`).toBe(0)
  return result
}

for (const viewport of [
  { name: "desktop", width: 1440, height: 900 },
  { name: "mobile", width: 402, height: 812 }
]) {
  test(`hollowed viewport captures match full captures on a large review diff (${viewport.name})`, async ({ page }, testInfo) => {
    test.skip(testInfo.project.name === "core-webkit-screenshot" && viewport.name !== "mobile", "WebKit regression coverage targets the mobile-sized case")
    test.setTimeout(600_000)
    await openLargeReview(page, viewport)
    if (viewport.name === "mobile") await addInnerScrolledSurface(page)

    // Top of the diff: rows below the fold get hollowed. Expanding the files
    // may have scrolled the page, so go back up first.
    await scrollDiffTo(page, 0)
    const top = await expectPixelParity(page, testInfo, `${viewport.name}-top`)
    expect(top.candidates).toBeGreaterThan(0)

    // Middle and bottom: rows on both sides of the viewport get hollowed.
    await scrollDiffTo(page, 0.5)
    const middle = await expectPixelParity(page, testInfo, `${viewport.name}-middle`)
    expect(middle.hollowed, "the middle of a long diff must hollow something, or the comparison is vacuous").toBeGreaterThan(0)
    // The point of hollowing: a long review must not cost a full-document
    // capture (measured ~17s full vs ~1.5s hollowed). A generous ratio, so CPU
    // contention cannot flake it.
    expect(middle.hollowMs, "hollowing must make a long review capture much faster").toBeLessThan(middle.fullMs / 3)

    // A row cut by the viewport edge: an odd offset, so the edge never lines up with a row boundary.
    await scrollDiffTo(page, 0.5, 7)
    await expectPixelParity(page, testInfo, `${viewport.name}-cut-row`)

    await scrollDiffTo(page, 1)
    await expectPixelParity(page, testInfo, `${viewport.name}-bottom`)

    // Inner horizontal scroll of a file's code: the scroll-position mirroring
    // pairs elements by position, which hollowing must not disturb.
    await scrollDiffTo(page, 0.5)
    await page.evaluate(() => {
      document.querySelectorAll<HTMLElement>("[data-testid='diff-file-scroll']").forEach((scroller) => {
        scroller.scrollLeft = Math.floor(scroller.scrollWidth / 3)
      })
    })
    await expectPixelParity(page, testInfo, `${viewport.name}-horizontal-scroll`)
  })
}

test("unsafe full-page fallback stays readable inside the mobile bug-report dialog", async ({ page }, testInfo) => {
  test.skip(!["core", "core-webkit-screenshot"].includes(testInfo.project.name), "Only core browser projects exercise this dialog")
  await page.setViewportSize({ width: 393, height: 852 })
  await signInAsDemo(page)

  await page.getByRole("button", { name: "Report a bug" }).first().click()
  const dialog = page.getByRole("dialog", { name: "Report a bug" })
  await expect(dialog).toBeVisible()
  await expect(page.getByText("Capturing...")).toBeHidden({ timeout: 30_000 })

  await page.evaluate(() => {
    for (const element of [document.body, document.documentElement]) {
      Object.defineProperties(element, {
        scrollHeight: { configurable: true, value: 40_000 },
        scrollWidth: { configurable: true, value: 40_000 }
      })
    }
  })

  await dialog.getByText("Full page", { exact: true }).click()
  const warning = dialog.getByText(/too complex for a safe full-page screenshot/i)
  await expect(warning).toBeVisible()
  await expect(dialog.getByLabel("Viewport")).toBeChecked()

  expect(await dialog.evaluate((element) => element.scrollLeft)).toBe(0)
  await expectContainedBy(dialog.getByText("Report a bug"), dialog)
  await expectContainedBy(warning, dialog)
  await expectContainedBy(dialog.getByText("Screenshot", { exact: true }), dialog)
  await expectContainedBy(dialog.getByText("Viewport", { exact: true }).last(), dialog)
})
