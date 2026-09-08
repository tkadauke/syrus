import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const PERFORMANCE_PATH = "/api/v1/app/admin/performance"
const REQUEST_PATH = "/api/v1/app/jobs/4430"
const REQUEST_ID = "request-4430"
const REQUEST_SQL = "SELECT `jobs`.* FROM `jobs` WHERE `jobs`.`state` = ?"
const PHASE_SQL = "SELECT `chat_messages`.* FROM `chat_messages` WHERE `chat_messages`.`chat_session_id` = ?"

// Genuine slow-request/slow-SQL telemetry is inherently nondeterministic (it
// depends on real wall-clock durations crossing a threshold), so this seeds a
// canned "request/run" the same shape PerformanceLogging emits -- a slow
// request event, its nested slow phase, and the SQL fingerprints both
// captured -- via route interception on the one listing endpoint. The SQL
// Explain endpoint underneath it has no such problem (it just runs a real
// EXPLAIN against whatever database is configured, no external service
// required), so that part of the flow is left unmocked and hits the real
// backend below.
function seededPerformancePayload() {
  return {
    enabled: true,
    current_revision: "e2e0000000000000",
    revision_scope: "current",
    thresholds: {
      slow_request_ms: 1000,
      slow_job_ms: 5000,
      slow_sql_ms: 250,
      slow_phase_ms: 250,
      request_sql_count_threshold: 50,
      request_sql_duration_ms: 500,
      top_sql_fingerprint_limit: 8,
      max_sql_fingerprints_per_request: 25
    },
    storage: {
      kind: "performance_log_events",
      max_events: 2000,
      expires_in_seconds: 86400,
      buffered: 0,
      dropped: 0
    },
    baseline: {
      revision: null,
      comparisons: { slow_requests: [], slow_jobs: [], slow_phases: [], browser_traces: [], sql_fingerprints: [] }
    },
    summaries: {
      slow_requests: [
        {
          method: "GET",
          path: REQUEST_PATH,
          controller: "Api::V1::App::JobsController",
          action: "show",
          count: 3,
          total_duration_ms: 3600,
          average_duration_ms: 1200,
          max_duration_ms: 1400,
          average_sql_count: 62,
          average_sql_duration_ms: 540,
          last_seen_at: "2026-09-01T12:00:00Z"
        }
      ],
      slow_jobs: [
        {
          job_class: "PollAllPullRequestsJob",
          queue_name: "polling",
          count: 1,
          total_duration_ms: 6200,
          average_duration_ms: 6200,
          max_duration_ms: 6200,
          average_sql_count: 40,
          average_sql_duration_ms: 900,
          slow_sql_count: 1,
          last_seen_at: "2026-09-01T12:00:05Z",
          recent_active_job_id: "job-4430",
          recent_trigger_reasons: [ "duration" ]
        }
      ],
      slow_phases: [
        {
          phase: "job_payload.dependencies",
          count: 1,
          total_duration_ms: 310,
          average_duration_ms: 310,
          max_duration_ms: 310,
          last_seen_at: "2026-09-01T12:00:01Z",
          recent_metadata: { job_id: 4430 }
        }
      ],
      browser_traces: [
        {
          name: "job_detail.route",
          path: "/jobs/4430",
          count: 1,
          total_duration_ms: 900,
          average_duration_ms: 900,
          max_duration_ms: 900,
          average_api_duration_ms: 700,
          max_api_duration_ms: 700,
          recent_api_request_ids: [ "frontend-request-9" ],
          last_seen_at: "2026-09-01T12:00:02Z",
          recent_metadata: {}
        }
      ],
      sql_fingerprints: [
        {
          fingerprint: "select_jobs_by_state",
          sample_sql: REQUEST_SQL,
          name: "Job Load",
          count: 50,
          total_duration_ms: 400,
          average_duration_ms: 8,
          max_duration_ms: 30
        }
      ]
    },
    events: [
      {
        event: "syrus.performance.slow_job",
        occurred_at: "2026-09-01T12:00:05Z",
        app_revision: "e2e0000000000000",
        duration_ms: 6200,
        job_class: "PollAllPullRequestsJob",
        active_job_id: "job-4430",
        queue_name: "polling",
        sql_count: 40,
        sql_duration_ms: 900,
        trigger_reasons: [ "duration" ]
      },
      {
        event: "syrus.performance.slow_request",
        occurred_at: "2026-09-01T12:00:00Z",
        app_revision: "e2e0000000000000",
        request_id: REQUEST_ID,
        duration_ms: 1200,
        method: "GET",
        path: REQUEST_PATH,
        controller: "Api::V1::App::JobsController",
        action: "show",
        sql_count: 62,
        sql_duration_ms: 540,
        top_sql_fingerprints: [
          {
            fingerprint: "select_jobs_by_state",
            sample_sql: REQUEST_SQL,
            name: "Job Load",
            count: 20,
            total_duration_ms: 400,
            max_duration_ms: 30
          }
        ]
      },
      {
        event: "syrus.performance.slow_phase",
        occurred_at: "2026-09-01T12:00:01Z",
        app_revision: "e2e0000000000000",
        request_id: REQUEST_ID,
        duration_ms: 310,
        phase: "job_payload.dependencies",
        metadata: { job_id: 4430 },
        sql_count: 5,
        sql_duration_ms: 120,
        top_sql_fingerprints: [
          {
            fingerprint: "select_chat_messages_by_session",
            sample_sql: PHASE_SQL,
            name: "Message Load",
            count: 5,
            total_duration_ms: 120,
            max_duration_ms: 40
          }
        ]
      }
    ]
  }
}

async function mockPerformanceEvents(page: Page) {
  await page.route((url) => url.pathname === PERFORMANCE_PATH, async (route) => {
    await route.fulfill({ json: seededPerformancePayload() })
  })
}

test("Syrus Dev Performance UI drills into a seeded request/run and runs a real SQL explain", async ({ page }) => {
  await signInAsDemo(page)
  await mockPerformanceEvents(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "Syrus Dev" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  await page.goto("/admin/performance")
  await expect(page.getByRole("heading", { name: "Performance" })).toBeVisible()

  // Overview tab surfaces the seeded request/run across every summary table.
  await expect(page.getByText(REQUEST_PATH, { exact: false }).first()).toBeVisible()
  await expect(page.getByText("PollAllPullRequestsJob")).toBeVisible()
  await expect(page.getByText("job_payload.dependencies")).toBeVisible()
  await expect(page.getByText("Job Load")).toBeVisible()

  // Requests tab: drill into the seeded request to see its phase + SQL breakdown.
  await page.getByRole("button", { name: "Requests", exact: true }).click()
  await page.getByRole("button", { name: "Details" }).click()
  const requestDialog = page.getByRole("dialog", { name: "Slow request SQL details" })
  await expect(requestDialog).toBeVisible()
  await expect(requestDialog.getByText(REQUEST_ID)).toBeVisible()
  await expect(requestDialog.getByText("Slow phases")).toBeVisible()
  await expect(requestDialog.getByText("job_payload.dependencies")).toBeVisible()
  await expect(requestDialog.getByText("Message Load")).toBeVisible()
  await expect(requestDialog.getByText("Job Load")).toBeVisible()

  // Explain the request-level SQL fingerprint. This hits the real backend --
  // there is no external dependency to fake here, unlike the MySQL/K8s
  // sibling plugins -- so it exercises the actual EXPLAIN QUERY PLAN path
  // against whichever database this preview is configured with.
  await requestDialog.locator("tr", { hasText: "Job Load" }).getByRole("button", { name: "Explain" }).click()
  const explainDialog = page.getByRole("dialog", { name: "SQL explain result" })
  await expect(explainDialog).toBeVisible()
  await expect(explainDialog.getByRole("button", { name: "Run EXPLAIN ANALYZE" })).toBeDisabled()

  await explainDialog.getByRole("button", { name: "Run EXPLAIN", exact: true }).click()
  await expect(explainDialog.getByText("Question-mark bind placeholders were substituted with NULL for EXPLAIN.")).toBeVisible()
  // EXPLAIN ANALYZE stays disabled after a real run too -- this repo's local/CI
  // preview database is SQLite, and the plugin only allows ANALYZE on MySQL.
  await expect(explainDialog.getByRole("button", { name: "Run EXPLAIN ANALYZE" })).toBeDisabled()

  await explainDialog.getByRole("button", { name: "SQL", exact: true }).click()
  await expect(explainDialog.getByText("SELECT `jobs`.* FROM `jobs` WHERE `jobs`.`state` = NULL")).toBeVisible()

  // Opening Explain closes the request drilldown modal underneath it (only one
  // modal renders at a time in AdminPerformance -- see openExplain's
  // setRequestDetail(null)), so closing Explain leaves no modal on screen at
  // all rather than reopening the request dialog.
  await explainDialog.getByRole("button", { name: "Close" }).click()
  await expect(page.getByRole("dialog")).toHaveCount(0)

  // Phases tab shows the same seeded phase outside of the request drilldown.
  await page.getByRole("button", { name: "Phases", exact: true }).click()
  await expect(page.getByRole("cell", { name: "job_payload.dependencies" })).toBeVisible()

  // SQL tab shows the seeded fingerprint and can explain it directly too.
  await page.getByRole("button", { name: "SQL", exact: true }).click()
  await expect(page.getByText(REQUEST_SQL)).toBeVisible()
})
