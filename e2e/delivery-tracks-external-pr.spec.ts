import { test, expect, type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { DEMO_USER, signInAsDemo } from "./support/auth"

test.slow()

type DeliveryFixture = {
  repositoryId: number
  forkRepositoryId: number
  promotionJobTitle: string
  hotfixJobTitle: string
  externalForkJobTitle: string
}

test("shows delivery-track configuration and recent external/fork PR ingestion", async ({ page }) => {
  skipWhenRemote()
  const fixture = createDeliveryFixture()

  await signInAsDemo(page)

  await openRepository(page, fixture.repositoryId)

  const delivery = page.getByRole("region", { name: "Delivery tracks" })
  await expect(delivery.getByRole("heading", { name: "Delivery" })).toBeVisible()

  const defaultTrack = delivery.getByRole("row").filter({ hasText: "default" })
  await expect(defaultTrack).toContainText("develop")
  await expect(defaultTrack).toContainText("review / landing / branch_health")
  await expect(defaultTrack).toContainText("1")
  await expect(defaultTrack).toContainText("develop")
  await expect(defaultTrack).toContainText("main")

  const hotfixTrack = delivery.getByRole("row", { name: /^hotfix release\/1\.0/ })
  await expect(hotfixTrack).toContainText("release/1.0")
  await expect(hotfixTrack).toContainText("hotfix_review / hotfix_landing / hotfix_health")
  await expect(hotfixTrack).toContainText("1")

  await expect(delivery.getByText("Ref-movement actions")).toBeVisible()
  await expect(delivery.getByText("send_job_upstream", { exact: true })).toBeVisible()
  await expect(delivery.getByText("submit_branch_upstream", { exact: true })).toBeVisible()
  await expect(delivery.getByText("Recent ref-movement workflows")).toBeVisible()
  await expect(delivery.getByText("promotion", { exact: true })).toBeVisible()
  await expect(delivery.getByText(/PR #\d+ \(open\)/)).toBeVisible()

  await expect(delivery.getByText("Recent PR ingestions")).toBeVisible()
  const ingestionRow = delivery.getByRole("row").filter({ hasText: "#337" })
  await expect(ingestionRow).toContainText("#337")
  await expect(ingestionRow).toContainText("external_fork")
  await expect(ingestionRow).toContainText("contributor/syrus-preview")

  await ingestionRow.getByRole("link", { name: /^JOB-\d+$/ }).click()
  await expect(page.getByRole("heading", { level: 1 })).toContainText(fixture.externalForkJobTitle)

  await expect(page.getByRole("link", { name: "PR #337", exact: true })).toBeVisible()

  await expect(page.getByText("Track", { exact: true })).toBeVisible()
  await expect(page.getByText("Target ref", { exact: true })).toBeVisible()
  await expect(page.getByText("External ingest", { exact: true })).toBeVisible()
  await expect(page.getByText(/feature\/fork-e2e.*demo\/syrus-preview:develop/)).toBeVisible()
})

test("shows external PR and delivery-status badges on the dashboard", async ({ page }) => {
  skipWhenRemote()
  const fixture = createDeliveryFixture()

  await signInAsDemo(page)
  await page.goto("/dashboard/jobs?ownership_scope=team&view=list")
  await page.getByRole("button", { name: "Remove Preset filter" }).click()

  const promotionRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: fixture.promotionJobTitle, exact: true }) })
  await expect(promotionRow).toContainText("Waiting for promotion")
  await expect(promotionRow).toContainText("PR #335")

  const externalRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: fixture.externalForkJobTitle, exact: true }) })
  await expect(externalRow).toContainText("External")
  await expect(externalRow).toContainText("PR #337")

  const hotfixRow = page.getByRole("row").filter({ has: page.getByRole("link", { name: fixture.hotfixJobTitle, exact: true }) })
  await expect(hotfixRow).toContainText("Syncing hotfix")
})

test("exposes fork sync and external PR ingestion controls on a fork repository", async ({ page }) => {
  skipWhenRemote()
  const fixture = createDeliveryFixture()

  await signInAsDemo(page)
  await page.goto(`/repositories/${fixture.forkRepositoryId}/edit`)

  await expect(page.getByRole("main", { name: "Edit Repository" })).toBeVisible()
  await expect(page.getByLabel("Upstream owner")).toHaveValue("demo")
  await expect(page.getByLabel("Upstream name")).toHaveValue("syrus-preview")
  await expect(page.getByLabel("Upstream default branch")).toHaveValue("main")
  await expect(page.getByLabel("Auto-sync this fork's default branch from its upstream")).toBeVisible()
  await expect(page.getByRole("button", { name: "Sync now" })).toBeVisible()
  await expect(page.getByLabel("Ingest externally-filed pull requests as Jobs")).toBeChecked()
})

async function openRepository(page: Page, repositoryId: number) {
  await page.goto(`/repositories/${repositoryId}`)
  await expect(page.getByRole("heading", { level: 1 })).toContainText("demo/syrus-preview")
}

function skipWhenRemote() {
  test.skip(!!process.env.E2E_BASE_URL, "Delivery-track E2E creates local preview fixture data and a local bare clone.")
}

function createDeliveryFixture(): DeliveryFixture {
  const output = execFileSync("bin/rails", ["runner", deliveryFixtureScript()], {
    env: process.env
  }).toString().trim()

  return JSON.parse(output) as DeliveryFixture
}

function deliveryFixtureScript(): string {
  const yml = `
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review
        landing: landing
        branch_health: branch_health
    hotfix:
      branch: release/1.0
      grade_phases:
        review: hotfix_review
        landing: hotfix_landing
        branch_health: hotfix_health
  promotion:
    enabled: true
    mode: manual_pr
    grade_phases: [promotion]
  hotfix_sync:
    enabled: true
    mode: manual_pr
  upstream_export:
    enabled: true
    mode: per_job_pr
  ref_movement_actions:
    send_job_upstream:
      enabled: true
      mode: manual_pr
      source: { kind: job_branch }
      target: { kind: upstream_intake }
    submit_branch_upstream:
      enabled: true
      mode: manual_pr
      source: { kind: delivery_track, track: default }
      target: { kind: upstream_intake }
external_prs:
  ingest:
    enabled: true
`

  return `
    require "fileutils"
    require "json"

    user = User.find_by!(email_address: ${JSON.stringify(DEMO_USER.email)})
    repository = Repository.find_by!(owner: "demo", name: "syrus-preview")
    repository.update!(
      user: user,
      default_branch: "main",
      external_pr_ingestion_enabled: true
    )

    work_dir = Dir.mktmpdir("syrus-e2e-delivery")
    begin
      system("git", "init", "-q", "-b", "main", work_dir, exception: true)
      system("git", "-C", work_dir, "config", "user.email", "e2e@example.com", exception: true)
      system("git", "-C", work_dir, "config", "user.name", "E2E", exception: true)
      File.write(File.join(work_dir, ".syrus.yml"), ${JSON.stringify(yml)})
      system("git", "-C", work_dir, "add", ".", exception: true)
      system("git", "-C", work_dir, "commit", "-q", "-m", "delivery config", exception: true)

      clone_path = RepositoryBareClone.path_for(repository)
      FileUtils.rm_rf(clone_path)
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir)
    end

    fork_repository = Repository.find_or_initialize_by(owner: "contributor", name: "syrus-preview")
    fork_repository.assign_attributes(
      user: user,
      upstream_repository: repository,
      upstream_owner: repository.owner,
      upstream_name: repository.name,
      upstream_default_branch: repository.default_branch,
      default_branch: "main",
      trigger_label: "syrus",
      polling_enabled: false,
      prepare_enabled: true,
      agent_provider: "codex",
      review_policy: "self",
      feedback_policy: "confirm",
      epic_dependency_policy: "linear",
      external_pr_ingestion_enabled: true,
      fork_auto_sync_enabled: true
    )
    fork_repository.save!

    stamp = "E2E delivery #{Time.current.to_i}"
    Job.where(repository: repository).where("issue_title LIKE ?", "E2E delivery %").destroy_all

    attrs = {
      user: user,
      owner_user: user,
      repository: repository,
      agent_provider: "codex",
      credential_mode: "pat",
      priority: "medium",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending"
    }

    promotion_job = Job.create!(attrs.merge(
      kind: "direct",
      issue_title: "#{stamp}: promote develop",
      issue_body: "E2E fixture: locally landed work waiting for promotion.",
      state: "implemented",
      pr_number: 335,
      branch_name: "syrus/e2e-delivery-promotion"
    ))
    Workflow.create!(
      job: promotion_job,
      user: user,
      trigger_kind: "promotion",
      agent_provider: "codex",
      state: "succeeded",
      created_at: 18.minutes.ago,
      started_at: 18.minutes.ago,
      finished_at: 16.minutes.ago,
      artifacts: {
        "promotion_source_branch" => "develop",
        "promotion_target_branch" => "main"
      }
    )
    JobPrLink.create!(
      job: promotion_job,
      role: JobPrLink::ROLE_PROMOTION,
      source_ref: "develop",
      target_repository: repository,
      target_ref: "main",
      pr_number: 336,
      metadata: { "pr_state" => "open" }
    )
    promotion_job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: 20.minutes.ago)

    waiting_promotion_job = Job.create!(attrs.merge(
      kind: "direct",
      issue_title: "#{stamp}: dashboard waiting for promotion",
      issue_body: "E2E fixture: locally landed work with no promotion PR yet.",
      state: "implemented",
      pr_number: 335,
      branch_name: "syrus/e2e-waiting-promotion"
    ))
    waiting_promotion_job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: 12.minutes.ago)

    hotfix_job = Job.create!(attrs.merge(
      kind: "direct",
      issue_title: "#{stamp}: sync hotfix back",
      issue_body: "E2E fixture: hotfix-track work waiting for sync-back.",
      state: "implemented",
      pr_number: 338,
      branch_name: "syrus/e2e-hotfix",
      delivery_track: "hotfix"
    ))
    hotfix_job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: 8.minutes.ago)

    external_job = Job.create!(attrs.merge(
      kind: "external_pr",
      issue_title: "#{stamp}: external fork PR",
      issue_body: "E2E fixture: externally-filed fork PR ingested as a Job.",
      state: "implemented",
      external_pr_number: 337,
      external_pr_author: "fork-contributor",
      external_pr_fork: true,
      branch_name: "feature/fork-e2e"
    ))
    JobPrLink.create!(
      job: external_job,
      role: JobPrLink::ROLE_EXTERNAL_INGEST,
      source_repository: fork_repository,
      source_ref: "feature/fork-e2e",
      target_repository: repository,
      target_ref: "develop",
      pr_number: 337,
      metadata: {
        "provenance" => "external_fork",
        "ingest_mode" => "review_and_grade",
        "source_repo_slug" => fork_repository.slug
      }
    )

    queued_default = Job.create!(attrs.merge(
      kind: "direct",
      issue_title: "#{stamp}: queued develop track",
      issue_body: "E2E fixture: default delivery queue length.",
      state: "approved",
      pr_number: 339,
      branch_name: "syrus/e2e-queued-develop",
      approved_at: 5.minutes.ago,
      approved_via: "operator",
      approved_by_user: user
    ))
    queued_hotfix = Job.create!(attrs.merge(
      kind: "direct",
      issue_title: "#{stamp}: queued hotfix track",
      issue_body: "E2E fixture: hotfix delivery queue length.",
      state: "approved",
      pr_number: 340,
      branch_name: "syrus/e2e-queued-hotfix",
      delivery_track: "hotfix",
      approved_at: 4.minutes.ago,
      approved_via: "operator",
      approved_by_user: user
    ))

    puts JSON.generate({
      repositoryId: repository.id,
      forkRepositoryId: fork_repository.id,
      promotionJobTitle: waiting_promotion_job.issue_title,
      hotfixJobTitle: hotfix_job.issue_title,
      externalForkJobTitle: external_job.issue_title
    })
  `
}
