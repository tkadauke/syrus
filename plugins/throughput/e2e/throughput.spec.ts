import { test, expect, type Page } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

const METRICS_PATH_RE = /\/api\/v1\/app\/repositories\/\d+\/throughput_metrics$/

// MetricContract computes every figure straight from Job/Workflow/Step/Run
// rows already in the database -- unlike the MySQL/K8s/Tailscale sibling
// plugins there is no external daemon to fake here. But its fixed windows
// (1h/4h/24h/7d) measure back from wall-clock "now", and the seeded demo
// repository's Workflow/Step chain (db/seeds.rb) is backdated relative to
// whenever db:seed last ran, not this test run -- exactly the "default
// window makes real seed-data timing unreliable" problem the Worker Timeline
// E2E spec ran into. So this seeds a canned metrics payload for two windows
// via route interception (still the real repository id, from real UI
// navigation) rather than depending on when the demo data was seeded.
function windowPayload({ prCreationCount, hours }: { prCreationCount: number; hours: number }) {
  const rate = (count: number, sampleCount = count) => ({
    count,
    per_hour: Math.round((count / hours) * 100) / 100,
    sample_count: sampleCount,
    confidence: sampleCount === 0 ? "none" : sampleCount < 5 ? "low" : sampleCount < 20 ? "medium" : "high"
  })
  const duration = (average: number | null, sampleCount = average == null ? 0 : 3) => ({
    sample_count: sampleCount,
    confidence: sampleCount === 0 ? "none" : sampleCount < 5 ? "low" : sampleCount < 20 ? "medium" : "high",
    average,
    p50: average,
    p95: average
  })

  return {
    range: { start: "2026-09-01T08:00:00Z", end: "2026-09-01T12:00:00Z", hours },
    pr_creation: {
      ...rate(prCreationCount),
      total_observed_count: prCreationCount,
      series: {
        syrus_authored: rate(prCreationCount),
        external: rate(0),
        fork_review: rate(0)
      }
    },
    output: {
      commits: rate(4),
      loc: { ...rate(120), additions: 150, deletions: 30, net: 120, unavailable_sample_count: 0 },
      by_job: []
    },
    landing: {
      landing_units: rate(1),
      jobs_landed: rate(1),
      attempts: { total_count: 1, successful: rate(1), failed: rate(0), cancelled: rate(0), deferred: rate(0) },
      unit_types: { auto_merge: { landing_units: 1, jobs_landed: 1 }, merge_train: { landing_units: 0, jobs_landed: 0 } },
      merge_train_size: { sample_count: 0, confidence: "none", average: null, max: null, values: [] },
      approved_to_landing_latency_seconds: duration(600),
      landing_start_to_closed_latency_seconds: duration(900),
      grader_phase_duration_seconds: duration(300),
      mergeability_rebase_wait_seconds: duration(null),
      base_moved_regrade_count: 0,
      reused_landing_validation_count: 0,
      current_optimistic_capacity: {
        sample_count: 3,
        confidence: "low",
        average_successful_unit_wall_time_seconds: 900,
        estimated_landing_units_per_hour: 4,
        estimated_jobs_landed_per_hour: 4,
        average_jobs_per_landing_unit: 1
      }
    },
    landing_waste: {
      failed_landing_attempts_per_successful_landing: { numerator: 0, denominator: 1, value: 0, confidence: "low" },
      failed_or_cancelled_landing_workflow_seconds: 0,
      failed_or_cancelled_landing_workflow_count: 0,
      deferred_landing_attempt_count: 0,
      failed_train_cooldown_seconds: 0,
      failed_train_cooldown_remaining_seconds: 0,
      rebase_churn_workflow_count: 0,
      rebase_churn_seconds: 0,
      landing_blocking_rebase_count: 0
    },
    review_funnel: {
      jobs_with_pr_feedback: 1,
      jobs_with_feedback_before_approval: 0,
      feedback_rounds: 2,
      jobs_approved_immediately_without_feedback: 1,
      approval_sources: {
        operator: { count: 1, sample_count: 1, confidence: "low" },
        auto: { count: 0, sample_count: 0, confidence: "none" },
        github_review: { count: 0, sample_count: 0, confidence: "none" },
        unknown: { count: 0, sample_count: 0, confidence: "none" }
      },
      pr_open_to_first_feedback_seconds: duration(1200),
      feedback_to_addressed_seconds: duration(1800),
      pr_open_to_approval_seconds: duration(3600),
      approval_latency_seconds: duration(3600),
      approval_to_landing_start_seconds: duration(600),
      approval_to_landing_latency_seconds: duration(600),
      approval_to_landed_seconds: duration(1500),
      approval_count: 2,
      approval_vote_count: 2,
      pr_opened_count: prCreationCount
    },
    samples: {
      jobs_seen: 5,
      prs_opened: prCreationCount,
      output_runs_with_diffs: 4,
      landed_jobs: 1,
      landing_workflows: 1,
      landing_units: 1,
      approvals: 2,
      approval_votes: 2,
      feedback_comments: 3
    }
  }
}

function metricsPayload() {
  const fourHour = windowPayload({ prCreationCount: 1, hours: 4 })
  const twentyFourHour = windowPayload({ prCreationCount: 3, hours: 24 })

  return {
    version: 1,
    repository_id: 1,
    generated_at: "2026-09-01T12:00:00Z",
    windows: {
      "1h": windowPayload({ prCreationCount: 0, hours: 1 }),
      "4h": fourHour,
      "24h": twentyFourHour,
      "7d": windowPayload({ prCreationCount: 3, hours: 168 }),
      last_active: fourHour
    }
  }
}

async function mockThroughputMetrics(page: Page) {
  await page.route(
    (url) => METRICS_PATH_RE.test(url.pathname),
    async (route) => {
      await route.fulfill({ json: metricsPayload() })
    }
  )
}

test("Throughput plugin renders repository delivery metrics", async ({ page }) => {
  await signInAsDemo(page)
  await mockThroughputMetrics(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "Throughput" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
  }

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  const panel = page.getByRole("region", { name: "Repository throughput" })
  await expect(panel).toBeVisible()
  await expect(panel.getByRole("heading", { name: "Throughput" })).toBeVisible()

  // Default window is 4h.
  await expect(panel.getByText("1 Syrus-authored, 1 observed")).toBeVisible()
  await expect(panel.getByText("+120 net LOC, 150+/30-")).toBeVisible()
  await expect(panel.getByText("1 auto, 0 trains")).toBeVisible()
  await expect(panel.getByText("1 jobs; train avg -")).toBeVisible()
  await expect(panel.getByText("Approval funnel")).toBeVisible()
  await expect(panel.getByText("Bottlenecks")).toBeVisible()
  await expect(panel.getByText("Latency and capacity")).toBeVisible()
  await expect(panel.getByText("2 jobs / 2 votes")).toBeVisible()
  await expect(panel.getByText("5 jobs", { exact: false })).toBeVisible()

  // The whole windows payload is fetched once; switching windows just
  // re-renders from a different key already in that response.
  await panel.getByRole("button", { name: "24h" }).click()
  await expect(panel.getByText("3 Syrus-authored, 3 observed")).toBeVisible()
})
