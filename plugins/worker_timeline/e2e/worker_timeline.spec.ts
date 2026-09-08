import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const MACRO_PATH = "/api/v1/app/admin/worker_timeline/macro"
const WORKFLOW_PATH = "/api/v1/app/admin/worker_timeline/workflow"

const SPAN_LABEL = "JOB-4432 · initial"
const PENDING_LABEL = "JOB-4433 · pr_comment"
const PENDING_JOB_TITLE = "Address feedback on the forum mural"

const emptyBlocked = {
  blocked_reason: null,
  blocked_since: null,
  blocked_details: {},
  next_check_at: null,
  available: true,
  historical: false
}

// There is no real multi-worker fleet with overlapping activity in this
// preview sandbox for the timeline to draw, and the default 3-hour window
// makes real seed-data timing unreliable, so this seeds a canned macro
// lane/span/pending entry and its per-workflow waterfall drill-down via
// route interception -- the same approach the Syrus Dev Performance UI E2E
// spec uses for its telemetry, since there's no external service here to
// fake either.
function macroPayload() {
  return {
    range: { from: "2026-09-01T09:00:00Z", to: "2026-09-01T12:00:00Z" },
    lanes: [
      {
        key: "worker-1:runs",
        worker_storage_key: "storage-key-abcdefgh12345",
        queue_role: "runs",
        hostname: "worker-1",
        pid: 4242,
        instance: null,
        spans: [
          {
            worker_storage_key: "storage-key-abcdefgh12345",
            queue_role: "runs",
            hostname: "worker-1",
            pid: 4242,
            workflow_id: 9001,
            job_id: 4432,
            started_at: "2026-09-01T10:00:00Z",
            finished_at: "2026-09-01T10:20:00Z",
            status: "succeeded",
            label: SPAN_LABEL,
            job_title: "Fix the aqueducts",
            blocked: emptyBlocked
          }
        ]
      }
    ],
    pending: [
      {
        workflow_id: 9002,
        job_id: 4433,
        label: PENDING_LABEL,
        job_title: PENDING_JOB_TITLE,
        created_at: "2026-09-01T11:55:00Z",
        blocked: { ...emptyBlocked, blocked_reason: "waiting for main branch health" }
      }
    ],
    filter: { and: [] },
    filter_schema: []
  }
}

function workflowPayload() {
  return {
    workflow: {
      id: 9001,
      job_id: 4432,
      trigger_kind: "initial",
      status: "succeeded",
      started_at: "2026-09-01T10:00:00Z",
      finished_at: "2026-09-01T10:20:00Z",
      worker_storage_key: "storage-key-abcdefgh12345",
      queue_role: "runs",
      hostname: "worker-1",
      pid: 4242,
      blocked: emptyBlocked
    },
    steps: [
      {
        id: 501,
        kind: "prepare",
        status: "succeeded",
        position: 0,
        iteration: 1,
        started_at: "2026-09-01T10:00:00Z",
        finished_at: "2026-09-01T10:02:00Z",
        worker_storage_key: "storage-key-abcdefgh12345",
        queue_role: "runs",
        hostname: "worker-1",
        pid: 4242,
        runs: [
          { id: 9101, status: "succeeded", iteration: 1, started_at: "2026-09-01T10:00:00Z", finished_at: "2026-09-01T10:02:00Z", last_heartbeat_at: null }
        ]
      },
      {
        id: 502,
        kind: "implement",
        status: "succeeded",
        position: 1,
        iteration: 1,
        started_at: "2026-09-01T10:02:00Z",
        finished_at: "2026-09-01T10:20:00Z",
        worker_storage_key: "storage-key-abcdefgh12345",
        queue_role: "runs",
        hostname: "worker-1",
        pid: 4242,
        runs: [
          { id: 9102, status: "succeeded", iteration: 1, started_at: "2026-09-01T10:02:00Z", finished_at: "2026-09-01T10:20:00Z", last_heartbeat_at: null }
        ]
      }
    ]
  }
}

async function mockTimelineData(page: Page) {
  await page.route((url) => url.pathname === MACRO_PATH, async (route) => {
    await route.fulfill({ json: macroPayload() })
  })
  await page.route((url) => url.pathname === WORKFLOW_PATH, async (route) => {
    await route.fulfill({ json: workflowPayload() })
  })
}

test("Worker Timeline plugin visualizes worker lanes and drills into a workflow waterfall", async ({ page }) => {
  await signInAsDemo(page)
  await mockTimelineData(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "Worker Timeline" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  await page.goto("/worker_timeline")
  await expect(page.getByRole("heading", { name: "Worker Timeline" })).toBeVisible()

  // Macro lane view: one lane for the seeded worker queue role, with the
  // seeded Workflow span drawn inside it.
  await expect(page.getByText("runs")).toBeVisible()
  await expect(page.getByRole("button", { name: SPAN_LABEL })).toBeVisible()

  // Waiting-to-start list surfaces the pending Workflow separately from the lanes.
  await expect(page.getByRole("heading", { name: "Waiting to start" })).toBeVisible()
  await expect(page.getByText("JOB-4433")).toBeVisible()
  await expect(page.getByText("pr_comment")).toBeVisible()
  await expect(page.getByText("Blocked: waiting for main branch health")).toBeVisible()

  // Click the span to drill into the per-workflow Step/Run waterfall.
  await page.getByRole("button", { name: SPAN_LABEL }).click()
  await expect(page.getByRole("heading", { name: "Workflow detail" })).toBeVisible()
  await expect(page.getByText("Workflow #9001 · initial · succeeded")).toBeVisible()
  await expect(page.getByText("prepare · iteration 1")).toBeVisible()
  await expect(page.getByText("implement · iteration 1")).toBeVisible()
  await expect(page.getByRole("img", { name: "Run #9101 · succeeded" })).toBeVisible()
  await expect(page.getByRole("img", { name: "Run #9102 · succeeded" })).toBeVisible()

  // Back link returns to the macro lane view.
  await page.getByRole("link", { name: "← Back to Worker Timeline" }).click()
  await expect(page.getByRole("heading", { name: "Worker Timeline" })).toBeVisible()
  await expect(page.getByRole("button", { name: SPAN_LABEL })).toBeVisible()
})
