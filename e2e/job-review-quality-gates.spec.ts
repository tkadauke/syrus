import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"
import { jobsListRow } from "./support/dashboard"

test.slow()

async function openImplementedDemoJob(page: Page) {
  const title = "Inspect preview dashboard states"

  const row = await jobsListRow(page, title)
  await row.getByRole("link", { name: title, exact: true }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(title)
}

async function openReviewTab(page: Page, expectedSnippets = ["app/services/dashboard_payload.rb", "app/frontend/routes/Dashboard.tsx", "needs_attention_count"]) {
  await page.getByRole("button", { name: "Review", exact: true }).click()
  await expect(page.getByRole("heading", { name: "Implementation review" })).toBeVisible()
  // The file-count summary under the heading. Anchored and count-agnostic: the
  // label is pluralized ("1 file" / "2 files"), so a literal match on either
  // form would break whenever the seeded diff's file count changes.
  await expect(page.getByText(/^\d+ files?$/)).toBeVisible()
  for (const snippet of expectedSnippets) {
    await expect(page.getByText(snippet).first()).toBeVisible()
  }
}

async function openWideLineComposerAndScrollDiff(page: Page) {
  await page.locator("[data-testid='diff-file-scroll']").first().evaluate((scrollRegion) => {
    const codeCell = scrollRegion.querySelector("td.whitespace-pre")
    if (!codeCell) throw new Error("diff code cell not found")
    codeCell.textContent = "very_wide_diff_line_" + "x".repeat(360)
  })
  await page.getByRole("button", { name: /^Comment on / }).first().click({ force: true })
  await page.locator("[data-testid='diff-file-scroll']").first().evaluate((scrollRegion) => {
    scrollRegion.scrollLeft = scrollRegion.scrollWidth
  })
  await page.waitForFunction(() => {
    const scrollRegion = document.querySelector("[data-testid='diff-file-scroll']")
    return Boolean(scrollRegion && scrollRegion.scrollLeft > 0)
  })
}

async function mockReviewSourceDiffWithMobileReviewNote(page: Page) {
  await page.route((url) => /^\/api\/v1\/app\/jobs\/[^/]+\/source_diff$/.test(url.pathname), async (route) => {
    const version = {
      id: 710,
      job_id: 1,
      version_index: 1,
      base_sha: "base-sha",
      head_sha: "head-sha",
      base_ref: "main",
      head_ref: "syrus/review-note-layout",
      workflow_id: null,
      workflow: null,
      run_id: null,
      trigger_kind: "initial",
      label: "Version 1",
      reason: "initial",
      truncated: false,
      files_count: 2,
      comments_count: 0,
      metadata: {},
      created_at: null
    }
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        job_id: 1,
        base_ref: "base-sha",
        head_ref: "head-sha",
        base_sha: "base-sha",
        head_sha: "head-sha",
        merge_base_sha: "base-sha",
        default_ref: "main",
        branch_commits: [],
        truncated: false,
        diff_error: null,
        version,
        versions: [version],
        files: [
          {
            additions: 16,
            deletions: 0,
            path: "src/engine/gpu_display.cpp",
            status: "modified",
            patch: [
              "diff --git a/src/engine/gpu_display.cpp b/src/engine/gpu_display.cpp",
              "--- a/src/engine/gpu_display.cpp",
              "+++ b/src/engine/gpu_display.cpp",
              "@@ -97,4 +99,20 @@ namespace render {",
              " context before the reviewed addition",
              "+",
              "+/// Display-resolve implementation for tone mapping",
              "+inline GpuDisplayResolveTonemap platformDisplayResolveTonemap(const std::string& tonemap) {",
              "+  if (!tonemap) {",
              "+    return GpuDisplayResolveTonemap::Linear;",
              "+  }",
              "+",
              "+  return tonemap->gpuDisplayResolveTonemap();",
              "+}",
              "+",
              "+/// True when tone mapping needs platform handling",
              "+inline bool supportsPlatformDisplayResolveTonemap(const std::string& tonemap) {",
              "+  return platformDisplayResolveTonemap(tonemap) != GpuDisplayResolveTonemap::Linear;",
              "+}",
              "+",
              "+// End platform display-resolve helpers.",
              " }",
              " trailing namespace context",
              " another trailing context",
              "@@ -504,6 +520,6 @@ namespace engine::graph {",
              "-bool supportsPlatformDisplayResolve(const RenderState& state) {",
              "-  return !tonemap || tonemap->gpuDisplayResolveTonemap();",
              "-}",
              "+bool supportsPlatformDisplayResolve(const RenderState& state) {",
              "+  return requestedOrPredictedGpuTracing(state);",
              "+}"
            ].join("\n")
          },
          {
            additions: 1,
            deletions: 0,
            path: "src/engine/gpu_display.h",
            status: "modified",
            patch: [
              "diff --git a/src/engine/gpu_display.h b/src/engine/gpu_display.h",
              "--- a/src/engine/gpu_display.h",
              "+++ b/src/engine/gpu_display.h",
              "@@ -1,2 +1,3 @@",
              " #pragma once",
              "+bool supportsPlatformDisplayResolveTonemap();"
            ].join("\n")
          }
        ],
        coverage_annotations: {},
        review_annotations: {
          annotations: {},
          ranges: {
            "src/engine/gpu_display.cpp": [
              {
                id: "cognitive_review_note:7",
                component: "cognitive_review/note_marker",
                marker_component: "cognitive_review/note_marker",
                inline_component: "cognitive_review/note_panel",
                path: "src/engine/gpu_display.cpp",
                side: "new",
                start_line: 104,
                end_line: 115,
                title: "Validate the platform tonemap fallback",
                body: "The provider flagged this added range.",
                tone: "warning",
                props: {
                  note_id: 7,
                  job_id: 1,
                  path: "src/engine/gpu_display.cpp",
                  side: "new",
                  start_line: 104,
                  end_line: 115,
                  title: "Validate the platform tonemap fallback",
                  explanation: "The inline Review Note card must be visible before the next hunk or file header on mobile.",
                  open_unhandled: true,
                  priority: "high",
                  confidence: 0.91,
                  reason_codes: ["mobile_layout"]
                }
              }
            ]
          },
          panels: [],
          actions: [],
          counts: [{ id: "cognitive_review.open", label: "Review Notes", value: 1, tone: "warning" }]
        }
      })
    })
  })
}

test("covers review diff, coverage, diff comments, and workflow warning action", async ({ page }) => {
  const commentBody = `E2E review note: verify the seeded diff quality gate ${Date.now()}`

  await signInAsDemo(page)
  await openImplementedDemoJob(page)

  await openReviewTab(page)
  await openWideLineComposerAndScrollDiff(page)

  const viewportWidth = page.viewportSize()?.width ?? 1280
  const layout = await page.evaluate(() => {
    const scroller = document.querySelector("[data-testid='diff-file-scroll']")?.getBoundingClientRect()
    const composer = document.querySelector("[data-testid='diff-review-composer'] textarea")?.getBoundingClientRect()
    const grid = document.querySelector("[data-testid='agent-diff-viewer']")?.closest(".grid")
    const sidebar = grid ? Array.from(grid.children).at(-1)?.getBoundingClientRect() : null

    return {
      bodyScrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      composerRight: composer?.right ?? 0,
      composerWidth: composer?.width ?? 0,
      scrollerWidth: scroller?.width ?? 0,
      sidebarRight: sidebar?.right ?? 0,
      sidebarWidth: sidebar?.width ?? 0
    }
  })

  expect(layout.bodyScrollWidth).toBeLessThanOrEqual(layout.clientWidth + 1)
  expect(layout.sidebarRight).toBeLessThanOrEqual(viewportWidth + 1)
  expect(layout.sidebarWidth).toBeLessThanOrEqual(384)
  expect(layout.composerRight).toBeLessThanOrEqual(viewportWidth + 1)
  expect(layout.composerWidth).toBeLessThanOrEqual(layout.scrollerWidth + 1)
  await page.getByRole("button", { name: "Cancel" }).click()

  await page.getByLabel("Whole-review comment").fill(commentBody)
  await page.getByRole("button", { name: "Comment", exact: true }).click()
  // The "Whole-review comment" label belongs to the composer, which closes on
  // save; the posted comment itself is what survives.
  await expect(page.getByText(commentBody)).toBeVisible()

  await page.getByRole("button", { name: "Summary", exact: true }).click()
  const coverage = page.getByTestId("coverage-card")
  await expect(coverage).toContainText("Coverage")
  await expect(coverage).toContainText("Lines")
  await expect(coverage).toContainText("87.1%")
  await expect(coverage).toContainText("PR delta:")
  await expect(coverage).toContainText("12/15 changed lines covered")
  await coverage.getByRole("button", { name: "Show 2 files" }).click()
  await expect(coverage).toContainText("app/services/dashboard_payload.rb")
  await expect(coverage).toContainText("app/frontend/routes/Dashboard.tsx")

  await page.getByRole("button", { name: /^Workflows \(\d+\)$/ }).click()
  await page.getByRole("button", { name: /Implement/i }).click()
  await expect(page.getByText("Branch coverage 70.2% is below the 75% threshold")).toBeVisible()
  await expect(page.getByRole("button", { name: "File a fix Job" })).toBeVisible()
})

test("shows inline Review Notes in the real review tab on a 402px mobile viewport", async ({ page }) => {
  await signInAsDemo(page)
  await mockReviewSourceDiffWithMobileReviewNote(page)
  await openImplementedDemoJob(page)
  await page.setViewportSize({ width: 402, height: 812 })
  await openReviewTab(page, ["src/engine/gpu_display.cpp", "src/engine/gpu_display.h"])

  const viewer = page.getByTestId("agent-diff-viewer")
  const annotatedRange = viewer.locator('[data-diff-review-annotation-ids~="cognitive_review_note:7"]').last()
  const marker = viewer.locator('[data-diff-review-annotation-marker="true"]').first()
  const inlineCard = viewer.locator('[data-testid="diff-review-annotation"] [data-cognitive-review-note-id="7"]')
  const nextHunk = viewer.locator('[data-diff-kind="hunk"]').nth(1)

  await expect(annotatedRange).toBeVisible()
  await expect(marker).toBeVisible()
  await expect(inlineCard).toBeVisible()
  await expect(inlineCard).toContainText("Validate the platform tonemap fallback")

  const layout = await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth
    const range = Array.from(document.querySelectorAll('[data-testid="agent-diff-viewer"] [data-diff-review-annotation-ids~="cognitive_review_note:7"]'))
      .at(-1)
      ?.getBoundingClientRect()
    const card = document
      .querySelector('[data-testid="agent-diff-viewer"] [data-testid="diff-review-annotation"] [data-cognitive-review-note-id="7"]')
      ?.getBoundingClientRect()
    const next = Array.from(document.querySelectorAll('[data-testid="agent-diff-viewer"] [data-diff-kind="hunk"]'))
      .at(1)
      ?.getBoundingClientRect()

    return {
      bodyScrollWidth: document.documentElement.scrollWidth,
      cardBottom: card?.bottom ?? 0,
      cardLeft: card?.left ?? -1,
      cardRight: card?.right ?? 0,
      cardTop: card?.top ?? 0,
      cardWidth: card?.width ?? 0,
      clientWidth: viewportWidth,
      nextTop: next?.top ?? 0,
      rangeBottom: range?.bottom ?? 0
    }
  })

  expect(layout.bodyScrollWidth).toBeLessThanOrEqual(layout.clientWidth + 1)
  expect(layout.cardWidth).toBeGreaterThan(240)
  expect(layout.cardLeft).toBeGreaterThanOrEqual(0)
  expect(layout.cardRight).toBeLessThanOrEqual(402)
  expect(layout.cardTop).toBeGreaterThanOrEqual(layout.rangeBottom)
  expect(layout.nextTop).toBeGreaterThan(layout.cardBottom)
  await expect(nextHunk).toBeVisible()
})

test("keeps the mobile line comment composer fixed after horizontal diff scrolling", async ({ page }) => {
  await signInAsDemo(page)
  await openImplementedDemoJob(page)
  await openReviewTab(page)
  await page.setViewportSize({ width: 390, height: 844 })
  await openWideLineComposerAndScrollDiff(page)

  const layout = await page.evaluate(() => {
    const composer = document.querySelector("[data-testid='diff-review-composer'] textarea")?.getBoundingClientRect()

    return {
      bodyScrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      composerLeft: composer?.left ?? 0,
      composerRight: composer?.right ?? 0,
      composerWidth: composer?.width ?? 0
    }
  })

  expect(layout.bodyScrollWidth).toBeLessThanOrEqual(layout.clientWidth + 1)
  expect(layout.composerLeft).toBeGreaterThanOrEqual(0)
  expect(layout.composerRight).toBeLessThanOrEqual(390)
  expect(layout.composerWidth).toBeGreaterThan(0)
})
