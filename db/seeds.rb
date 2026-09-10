# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

require_relative "seeds/themes"
Seeds::Themes.seed!

# Default any user still on no color theme (fresh migration, pre-the relevant change
# accounts) to the built-in Terracotta theme. New users get this via
# User#seed_default_color_theme; this backfills existing rows once Themes
# exist.
if (terracotta = Theme.terracotta)
  User.where(color_theme_id: nil).update_all(color_theme_id: terracotta.id)
end

# Development/preview sample data. Keep this intentionally small: enough to make
# a fresh preview useful for navigation, dashboard states, and chat rendering,
# but not a comprehensive fixture factory. Future agents may add one or two
# targeted rows when a UI surface is otherwise impossible to exercise, but avoid
# broad scenario dumps that slow previews or obscure real empty-state behavior.
if Rails.env.development?
  demo_user = User.find_or_initialize_by(email_address: "demo@syrus.local")
  demo_user.assign_attributes(
    name: "Demo Operator",
    first_name: "Demo",
    last_name: "Operator",
    global_role: "admin",
    agent_provider: "codex",
    chat_provider: "codex"
  )
  demo_user.password = "password" if demo_user.new_record? || demo_user.password_digest.blank?
  demo_user.save!

  # Team Directory (plugins/team_directory) hides its sidebar nav entry and
  # collapses the page to a "single user" empty state below two users, so a
  # fresh preview needs a second lightweight teammate for the directory list
  # (and the demo user's own card within it) to actually be reachable.
  teammate_user = User.find_or_initialize_by(email_address: "ada@syrus.local")
  teammate_user.assign_attributes(
    name: "Ada Lovelace",
    first_name: "Ada",
    last_name: "Lovelace",
    github_handle: "ada",
    profile_bio: "Keeps the analytical engines honest.",
    agent_provider: "codex",
    chat_provider: "codex"
  )
  teammate_user.password = "password" if teammate_user.new_record? || teammate_user.password_digest.blank?
  teammate_user.save!

  demo_repo = Repository.find_or_initialize_by(owner: "demo", name: "syrus-preview")
  demo_repo.assign_attributes(
    user: demo_user,
    default_branch: "main",
    trigger_label: "syrus",
    polling_enabled: false,
    prepare_enabled: true,
    agent_provider: "codex",
    review_policy: "self",
    feedback_policy: "confirm",
    epic_dependency_policy: "linear"
  )
  demo_repo.save!

  demo_chat = ChatSession.find_or_initialize_by(user: demo_user, title: "Preview walkthrough")
  demo_chat.assign_attributes(
    mode: "planning",
    pinned: true,
    last_message_at: Time.current,
    # Marks the "Meet Syrus in chat" onboarding step complete so a fresh
    # preview reaches the real Dashboard instead of being stuck on the
    # onboarding checklist (App::SetupStatus#chat_started? checks
    # User#onboarding_chat_started?, which requires a ChatSession with
    # onboarding: true).
    onboarding: true
  )
  demo_chat.repository = demo_repo if demo_chat.new_record?
  demo_chat.save!

  if demo_chat.messages.none?
    ChatMessage.create!(
      chat_session: demo_chat,
      role: "user",
      content: { "text" => "Show me what is happening in this preview." }
    )
    ChatMessage.create!(
      chat_session: demo_chat,
      role: "assistant",
      content: { "text" => "This preview is seeded with a small demo repository, one epic, and representative jobs so the dashboard is not empty." }
    )
  end

  demo_epic = Epic.find_or_initialize_by(repository: demo_repo, title: "Preview the operator workflow")
  demo_epic.assign_attributes(
    user: demo_user,
    owner_user: demo_user,
    description: "Small development seed that exercises the dashboard without starting automation.",
    state: "in_progress",
    epic_dependency_policy: "linear"
  )
  demo_epic.save!

  demo_jobs_by_title = {}

  # Real diff-review data for the seeded implemented Job (below), so the Job
  # detail Review tab has something to render even though the demo repo has
  # no GitHub credentials (App::JobSourceDiffPayload#preview_fixture reads
  # this column instead of calling GithubClient in development). Keep this
  # fixture-only: it is never applied to real files, only rendered as diff
  # text in the preview UI.
  demo_diff_review_fixture = {
    base_ref: "main",
    head_ref: "a1c9f7e0b2d4536170849f2ab6c3d8e1f0a9b7c6",
    merge_base_sha: "7a6b5c4d3e2f10908070605040302010fedcba9",
    branch_commits: [
      {
        sha: "a1c9f7e0b2d4536170849f2ab6c3d8e1f0a9b7c6",
        short_sha: "a1c9f7e",
        message: "Surface needs-attention badge in Dashboard header",
        date: "2026-09-03T15:41:00Z"
      },
      {
        sha: "f1e2d3c4b5a697887766554433221100ffeeddc",
        short_sha: "f1e2d3c",
        message: "Add needs_attention_count to dashboard summary",
        date: "2026-09-03T14:22:00Z"
      }
    ],
    files: [
      {
        path: "app/services/dashboard_payload.rb",
        status: "modified",
        additions: 5,
        deletions: 0,
        patch: [
          "diff --git a/app/services/dashboard_payload.rb b/app/services/dashboard_payload.rb",
          "index 2345678..9abcdef 100644",
          "--- a/app/services/dashboard_payload.rb",
          "+++ b/app/services/dashboard_payload.rb",
          "@@ -6,9 +6,14 @@ class DashboardPayload",
          "    def build",
          "      {",
          "        summary: summary_json,",
          "+        needs_attention_count: needs_attention_count,",
          "        jobs: jobs_json,",
          "        epics: epics_json",
          "      }",
          "    end",
          " ",
          "+    def needs_attention_count",
          "+      @jobs.count(&:needs_attention?)",
          "+    end",
          "+",
          "    private"
        ].join("\n")
      },
      {
        path: "app/frontend/routes/Dashboard.tsx",
        status: "modified",
        additions: 4,
        deletions: 1,
        patch: [
          "diff --git a/app/frontend/routes/Dashboard.tsx b/app/frontend/routes/Dashboard.tsx",
          "index 1234567..89abcde 100644",
          "--- a/app/frontend/routes/Dashboard.tsx",
          "+++ b/app/frontend/routes/Dashboard.tsx",
          "@@ -12,7 +12,7 @@ import { useT } from \"../hooks/useT\"",
          " import { StatTile } from \"../components/StatTile\"",
          " import { JobList } from \"./dashboard/JobList\"",
          " ",
          "-const REFRESH_INTERVAL_MS = 30000",
          "+const REFRESH_INTERVAL_MS = 15000",
          " ",
          " export function Dashboard() {",
          "   const { t } = useT(\"dashboard\")",
          "@@ -24,6 +24,9 @@ export function Dashboard() {",
          "   const summary = useQuery({",
          "     queryFn: fetchDashboardSummary,",
          "     refetchInterval: REFRESH_INTERVAL_MS",
          "   })",
          "+  const needsAttentionCount = summary.data?.needs_attention_count ?? 0",
          "+",
          "+  if (needsAttentionCount > 0) trackNeedsAttentionBadge(needsAttentionCount)",
          " ",
          "   return ("
        ].join("\n")
      },
      {
        path: "spec/services/dashboard_payload_spec.rb",
        status: "added",
        additions: 13,
        deletions: 0,
        patch: [
          "diff --git a/spec/services/dashboard_payload_spec.rb b/spec/services/dashboard_payload_spec.rb",
          "new file mode 100644",
          "index 0000000..abc1234",
          "--- /dev/null",
          "+++ b/spec/services/dashboard_payload_spec.rb",
          "@@ -0,0 +1,13 @@",
          "+require \"rails_helper\"",
          "+",
          "+RSpec.describe DashboardPayload do",
          "+  it \"includes a needs_attention_count in the summary\" do",
          "+    user = Factories.user",
          "+    repo = Factories.repository(user: user)",
          "+    Factories.job(repository: repo, state: \"failed\")",
          "+",
          "+    payload = described_class.new(user: user).build",
          "+",
          "+    expect(payload[:needs_attention_count]).to eq(1)",
          "+  end",
          "+end"
        ].join("\n")
      }
    ]
  }.deep_stringify_keys

  [
    {
      title: "Inspect preview dashboard states",
      state: "implemented",
      body: "Representative implemented job with a PR waiting for review.",
      pr_number: 101,
      branch_name: "syrus/demo-dashboard-states",
      diff_fixture: demo_diff_review_fixture,
      # The demo repository leaves auto-merge off by default (a deliberate,
      # unconfigured starting point for a fresh preview), but the Approve
      # button on an implemented Job hard-gates on `job.auto_merge_enabled?`
      # (repository setting OR this per-Job override) before it will even
      # transition the Job -- without this override, clicking Approve in a
      # fresh preview always 422s. Override it just on this one seeded Job
      # instead of flipping the repository-wide setting, so approving it is
      # actually reachable without changing the demo repo's default posture.
      auto_merge_enabled: true
    },
    {
      title: "Repair seeded background workflow",
      state: "failed",
      body: "Representative failed job for retry and failure UI affordances.",
      pr_number: 102,
      branch_name: "syrus/demo-repair-workflow"
    },
    {
      title: "Document preview seed guidance",
      state: "closed",
      body: "Representative completed job for closed-state rendering.",
      pr_number: 103,
      branch_name: "syrus/demo-seed-guidance",
      closure_reason: "pr_merged",
      finished_at: 1.hour.ago
    },
    {
      title: "Coordinate scheduled task rollout",
      state: "queued",
      body: "Representative freshly-triaged job waiting for its first workflow to start."
    },
    {
      title: "Approve trigger label rollout",
      state: "approved",
      body: "Representative approved job waiting in the landing queue.",
      pr_number: 104,
      branch_name: "syrus/demo-approved-rollout",
      approved_at: 30.minutes.ago,
      approved_via: "operator",
      approved_by_user: demo_user
    }
  ].each do |attrs|
    job = Job.find_or_initialize_by(
      repository: demo_repo,
      kind: "direct",
      issue_title: attrs.fetch(:title)
    )
    job.assign_attributes(
      user: demo_user,
      owner_user: demo_user,
      epic: demo_epic,
      issue_body: attrs.fetch(:body),
      state: attrs.fetch(:state),
      pr_number: attrs[:pr_number],
      branch_name: attrs[:branch_name],
      agent_provider: "codex",
      credential_mode: "pat",
      priority: "medium",
      job_provider_setting: "default",
      stack_base: "auto",
      validity: "valid",
      triaging_reason: "classifier_pending",
      closure_reason: attrs[:closure_reason],
      finished_at: attrs[:finished_at],
      approved_at: attrs[:approved_at],
      approved_via: attrs[:approved_via],
      approved_by_user: attrs[:approved_by_user],
      diff_fixture: attrs[:diff_fixture],
      auto_merge_enabled: attrs.fetch(:auto_merge_enabled, false)
    )
    job.save!
    demo_jobs_by_title[attrs.fetch(:title)] = job
  end

  # One seeded Job gets a full Workflow/Step/Run chain (with a diff, a
  # summary, and a couple of transcript lines) so the Job/Workflow detail
  # views have something real to drill into instead of an empty panel.
  # Picking the already-"implemented" job keeps this consistent with its
  # own state (implemented == a completed initial workflow that opened a PR).
  implemented_job = demo_jobs_by_title.fetch("Inspect preview dashboard states")
  if implemented_job.workflows.none?
    demo_workflow = Workflow.create!(
      job: implemented_job,
      user: demo_user,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "succeeded",
      started_at: 2.hours.ago,
      finished_at: 90.minutes.ago,
      artifacts: {
        "pr_title" => "Inspect preview dashboard states",
        "pr_body" => "Adds representative demo data so the dashboard and job detail views aren't empty in a fresh preview.",
        "summary" => "Seeded a demo repository, epic, and jobs spanning several states for preview navigation."
      }
    )

    step_specs = [
      { kind: "prepare" },
      { kind: "implement" },
      { kind: "summarize" },
      { kind: "test_plan" },
      { kind: "pr_open" }
    ]

    steps = step_specs.each_with_index.map do |spec, index|
      step_started = 2.hours.ago + (index * 5).minutes
      Step.create!(
        workflow: demo_workflow,
        kind: spec.fetch(:kind),
        position: index,
        iteration: 1,
        state: "succeeded",
        started_at: step_started,
        finished_at: step_started + 4.minutes
      )
    end
    steps.each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }

    implement_diff = <<~DIFF
      diff --git a/db/seeds.rb b/db/seeds.rb
      +  demo_jobs_by_title = {}
      +  # ...representative jobs in a few more states, plus a full
      +  # Workflow/Step/Run chain for one of them.
    DIFF

    steps.each do |step|
      run = Run.create!(
        job: implemented_job,
        user: demo_user,
        step: step,
        trigger_kind: "initial",
        agent_provider: "codex",
        state: "succeeded",
        iteration: 1,
        started_at: step.started_at,
        finished_at: step.finished_at,
        base_sha: "a1b2c3d",
        head_sha: "e5f6a7b",
        prompt: step.kind == "implement" ? "Broaden db/seeds.rb so the preview has richer Job/Workflow/Step/Run data to click through." : nil,
        agent_diff: step.kind == "implement" ? implement_diff : nil,
        agent_summary: step.kind == "summarize" ? "Broadened db/seeds.rb with a full Workflow/Step/Run chain and two additional Job states." : nil,
        agent_pr_title: step.kind == "summarize" ? "Inspect preview dashboard states" : nil,
        agent_pr_body: step.kind == "summarize" ? "Seeds a representative Workflow/Step/Run chain and a couple of extra Job states for preview navigation." : nil,
        cost_usd: step.kind.in?(%w[implement summarize test_plan]) ? 0.0421 : nil,
        input_tokens: step.kind.in?(%w[implement summarize test_plan]) ? 18342 : nil,
        output_tokens: step.kind.in?(%w[implement summarize test_plan]) ? 1211 : nil
      )

      next unless step.kind == "implement"

      JobLog.append!(run: run, kind: "agent", chunk: "Reviewing db/seeds.rb for preview coverage gaps.")
      JobLog.append!(run: run, kind: "agent", chunk: "Adding a full Workflow/Step/Run chain for the implemented demo job, plus queued/approved demo jobs.")
    end
  end

  # The seeded "failed" Job also gets a real (failed) Workflow/Step chain --
  # without one, `App::JobRetryActions` has no failed Step to point at, so
  # the Job detail page's only recovery action is "Start over" (which
  # abandons the branch and creates a whole new Job). A real failed
  # `implement` Step is what makes the "Retry failed step" / "Retry
  # implementation" affordances -- the actually-common recovery path --
  # reachable in a fresh preview at all.
  failed_job = demo_jobs_by_title.fetch("Repair seeded background workflow")
  if failed_job.workflows.none?
    failed_workflow = Workflow.create!(
      job: failed_job,
      user: demo_user,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "failed",
      started_at: 40.minutes.ago,
      finished_at: 25.minutes.ago,
      failure_reason: "grader_failed"
    )

    failed_prepare_step = Step.create!(
      workflow: failed_workflow,
      kind: "prepare",
      position: 0,
      iteration: 1,
      state: "succeeded",
      started_at: 40.minutes.ago,
      finished_at: 39.minutes.ago
    )
    failed_implement_step = Step.create!(
      workflow: failed_workflow,
      kind: "implement",
      position: 1,
      iteration: 1,
      state: "failed",
      started_at: 38.minutes.ago,
      finished_at: 25.minutes.ago
    )
    failed_prepare_step.update!(next_step_id: failed_implement_step.id)

    Run.create!(
      job: failed_job,
      user: demo_user,
      step: failed_prepare_step,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "succeeded",
      iteration: 1,
      started_at: failed_prepare_step.started_at,
      finished_at: failed_prepare_step.finished_at
    )
    failed_run = Run.create!(
      job: failed_job,
      user: demo_user,
      step: failed_implement_step,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "failed",
      iteration: 1,
      started_at: failed_implement_step.started_at,
      finished_at: failed_implement_step.finished_at,
      prompt: "Repair the background workflow that keeps failing on retry."
    )

    JobLog.append!(run: failed_run, kind: "agent", chunk: "Attempting to repair the background workflow retry path.")
    JobLog.append!(run: failed_run, kind: "system", chunk: "Required grader failed: bin/rspec spec/jobs/run_job_spec.rb")
  end

  # Build Cache sample sccache stats capture. The plugin is enabled by
  # default, but SCCACHE_BUCKET is normally unset in preview (no S3-compatible
  # bucket configured), so the admin Build Cache page always renders its real
  # "not configured" state -- worth exercising as-is rather than faking a
  # bucket. The per-Job hit/miss card (BuildCache::UiSlots, job.detail slot)
  # is driven entirely by a Workflow artifact instead, independent of the
  # bucket being configured, so seed one capture on the implemented demo
  # Job's prepare Run to give the Job Detail page real hit-rate data to render.
  build_cache_workflow = implemented_job.workflows.order(:created_at).first
  if build_cache_workflow && BuildCache::StatsArtifact.read(build_cache_workflow).empty?
    prepare_run = build_cache_workflow.steps.find_by(kind: "prepare")&.runs&.first
    if prepare_run
      BuildCache::StatsArtifact.record!(
        build_cache_workflow,
        run: prepare_run,
        step_kind: "prepare",
        label: "bundle install",
        stats: {
          "cache_hits" => 42,
          "cache_misses" => 8,
          "cache_size" => "256 MiB",
          "max_cache_size" => "10 GiB",
          "cache_location" => "S3, bucket: sccache-demo"
        }
      )
    end
  end

  # Rails plugin typed artifact renderer sample data. The rails plugin
  # (enabled by default) renders rails_schema_erd/rails_migration_diff typed
  # artifacts on the Job detail Review tab (SyrusRails::SchemaErdRenderer /
  # MigrationDiffRenderer, dispatched through TypedArtifactPanel), but a
  # fresh preview never runs a real agent turn that calls submit_artifact --
  # seed both on the implemented demo Job's workflow so the ERD diagram and
  # migration diff renderers have real data to show.
  rails_artifact_workflow = implemented_job.workflows.order(:created_at).first
  if rails_artifact_workflow
    existing_typed_artifact_types = Array(rails_artifact_workflow.artifact("typed_artifacts")).map { |entry| entry["type"] }

    unless existing_typed_artifact_types.include?("rails_schema_erd")
      rails_artifact_workflow.set_typed_artifact!(
        type: "rails_schema_erd",
        title: "Schema ERD",
        payload: {
          "tables" => [
            {
              "name" => "users",
              "columns" => [
                { "name" => "id", "type" => "integer" },
                { "name" => "email", "type" => "string" },
                { "name" => "account_id", "type" => "integer" }
              ],
              "indexes" => [
                { "name" => "index_users_on_email", "columns" => [ "email" ], "unique" => true }
              ],
              "foreign_keys" => [
                { "from_column" => "account_id", "to_table" => "accounts", "to_column" => "id" }
              ]
            },
            {
              "name" => "accounts",
              "columns" => [
                { "name" => "id", "type" => "integer" },
                { "name" => "name", "type" => "string" }
              ],
              "indexes" => [],
              "foreign_keys" => []
            }
          ]
        }
      )
    end

    unless existing_typed_artifact_types.include?("rails_migration_diff")
      rails_artifact_workflow.set_typed_artifact!(
        type: "rails_migration_diff",
        title: "Migration: AddNeedsAttentionCountToUsers",
        payload: {
          "migration_name" => "AddNeedsAttentionCountToUsers",
          "before" => {
            "table_name" => "users",
            "columns" => [
              { "name" => "id", "type" => "integer" },
              { "name" => "email", "type" => "string" }
            ]
          },
          "after" => {
            "table_name" => "users",
            "columns" => [
              { "name" => "id", "type" => "integer" },
              { "name" => "email", "type" => "string" },
              { "name" => "needs_attention_count", "type" => "integer" }
            ]
          },
          "changes" => [
            { "type" => "added", "column" => { "name" => "needs_attention_count", "type" => "integer" } }
          ]
        }
      )
    end
  end

  # Coverage report sample data for the core Job detail Summary/Review
  # surfaces. A fresh preview does not run coverage_analyze, but the operator
  # review flow should still show realistic coverage numbers, PR-delta data,
  # and changed-file breakdowns for the seeded implemented Job.
  quality_gate_workflow = implemented_job.workflows.order(:created_at).first
  if quality_gate_workflow && quality_gate_workflow.artifact("coverage").blank?
    quality_gate_workflow.set_artifact!(
      "coverage",
      {
        "summary" => {
          "lines_pct" => 87.1,
          "branches_pct" => 70.2,
          "functions_pct" => 91.4
        },
        "pr_delta" => {
          "covered" => 12,
          "total" => 15,
          "pct" => 80.0,
          "uncovered_files" => [ "app/services/dashboard_payload.rb" ]
        },
        "threshold_miss" => false,
        "files" => {
          "app/services/dashboard_payload.rb" => {
            "lines_pct" => 76.5,
            "branches_pct" => 61.2
          },
          "app/frontend/routes/Dashboard.tsx" => {
            "lines_pct" => 92.3,
            "branches_pct" => 84.0
          }
        },
        "sources_status" => [
          { "artifact" => "coverage/lcov.info", "found" => true, "lines_pct" => 87.1 }
        ],
        "hit_map_attached" => false
      }
    )
  end

  if quality_gate_workflow
    implement_step = quality_gate_workflow.steps.find_by(kind: "implement")
    if implement_step
      warning = quality_gate_workflow.workflow_warnings.find_or_initialize_by(
        kind: "coverage_branches_threshold_miss",
        step: implement_step
      )
      warning.assign_attributes(
        job: implemented_job,
        severity: "medium",
        title: "Branch coverage 70.2% is below the 75% threshold",
        evidence: {
          "branches_pct" => 70.2,
          "threshold_branches" => 75,
          "file" => "app/services/dashboard_payload.rb"
        },
        suggested_prompt: "Add tests that exercise the dashboard needs-attention count branches and raise branch coverage above the configured threshold.",
        state: "pending",
        created_job: nil
      )
      warning.save!
    end
  end

  # Agent Insights sample report. The plugin is off by default
  # (default_enabled: false), so a fresh preview shows it disabled on
  # Admin -> Plugins, same as a real install -- but the repository's
  # Insights tab has a real generated-looking report ready the moment an
  # operator enables it, instead of an empty state. Referencing
  # AgentInsights::Suggestion here is safe even while the plugin is
  # disabled: a disabled plugin's app/ tree stays on the Zeitwerk autoload
  # path, it just isn't eager loaded. Job#kind="agent_insight" is only a
  # valid enum value while the plugin is enabled (Job::Kind reads
  # kinds from enabled plugins), so the plugin is toggled on for just long
  # enough to create the fixture, then restored to its default-off state.
  insight_plugin = PluginRecord.find_or_create_by!(name: "agent_insights")
  insight_plugin_was_enabled = insight_plugin.enabled
  insight_plugin.update!(enabled: true) unless insight_plugin_was_enabled

  begin
    insight_job = Job.find_or_initialize_by(
      repository: demo_repo,
      kind: "agent_insight",
      issue_title: "Insight analysis: #{demo_repo.slug}"
    )
    insight_job.assign_attributes(
      user: demo_user,
      owner_user: demo_user,
      priority: "low",
      state: "closed",
      closure_reason: "agent_insight",
      finished_at: 45.minutes.ago
    )
    insight_job.save!

    failed_job = demo_jobs_by_title["Repair seeded background workflow"]

    AgentInsights::Suggestion.find_or_create_by!(
      job: insight_job,
      repository: demo_repo,
      title: "Repair workflows keep failing at the same implement step"
    ) do |suggestion|
      suggestion.category = "repeated_failure"
      suggestion.severity = "medium"
      suggestion.confidence = 0.78
      suggestion.state = "pending"
      suggestion.proposal_type = "create_job"
      suggestion.suggested_prompt = "Investigate why the implement step keeps failing on retry workflows for demo/syrus-preview and add regression coverage for the underlying cause."
      suggestion.evidence = failed_job ? [ { "job_id" => failed_job.id, "kind" => "repeated_failure" } ] : []
    end
  ensure
    insight_plugin.update!(enabled: false) unless insight_plugin_was_enabled
  end

  # Test Insights sample data. The plugin is enabled by default, but it only
  # ever writes rows when a real grader run parses JUnit output -- a fresh
  # preview never runs graders, so the repository's Tests tab would render
  # its empty state forever without a fixture. Seed one failing, one flaky,
  # and one slow test identity with a short run history so the "interesting
  # tests" list (failing / flaky / slow) has something real to show.
  if TestInsights::TestIdentity.for_repository(demo_repo).none?
    test_fixture_job = demo_jobs_by_title.fetch("Inspect preview dashboard states")
    run_offsets = [ 4.days, 3.days, 2.days, 1.day ]

    [
      {
        suite_name: "Billing::DiscountCalculatorTest",
        name: "raises when the discount exceeds the order total",
        file_path: "spec/services/billing/discount_calculator_spec.rb",
        statuses: %w[failed failed failed failed],
        duration_ms: 180,
        failure_message: "expected DiscountExceedsTotalError to be raised, but nothing was raised"
      },
      {
        suite_name: "Webhooks::DeliveryWorkerTest",
        name: "retries once before giving up on a flaky webhook delivery",
        file_path: "spec/workers/webhooks/delivery_worker_spec.rb",
        statuses: %w[passed failed passed failed],
        duration_ms: 220,
        failure_message: "Timeout::Error: execution expired"
      },
      {
        suite_name: "DashboardPayloadTest",
        name: "renders the full dashboard summary payload",
        file_path: "spec/services/dashboard_payload_spec.rb",
        statuses: %w[passed passed passed passed],
        duration_ms: 2150,
        failure_message: nil
      }
    ].each do |fixture|
      identity = TestInsights::TestIdentity.create!(
        repository: demo_repo,
        fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: fixture.fetch(:suite_name), name: fixture.fetch(:name)),
        suite_name: fixture.fetch(:suite_name),
        name: fixture.fetch(:name),
        file_path: fixture.fetch(:file_path)
      )

      fixture.fetch(:statuses).each_with_index do |status, index|
        occurred_at = run_offsets.fetch(index).ago
        fixture_run = Run.create!(
          job: test_fixture_job,
          user: demo_user,
          trigger_kind: "initial",
          agent_provider: "codex",
          state: "succeeded",
          started_at: occurred_at,
          finished_at: occurred_at + 3.minutes
        )
        test_run = TestInsights::TestRun.create!(
          run: fixture_run,
          repository: demo_repo,
          grader_name: "rspec",
          total_count: 1,
          passed_count: status == "passed" ? 1 : 0,
          failed_count: status == "failed" ? 1 : 0,
          skipped_count: 0,
          error_count: 0,
          duration_ms: fixture.fetch(:duration_ms)
        )
        TestInsights::TestCase.create!(
          test_run: test_run,
          repository: demo_repo,
          test_identity: identity,
          suite_name: fixture.fetch(:suite_name),
          name: fixture.fetch(:name),
          status: status,
          duration_ms: fixture.fetch(:duration_ms),
          failure_message: status == "passed" ? nil : fixture[:failure_message],
          created_at: occurred_at,
          updated_at: occurred_at
        )
      end

      identity.refresh_summary!
    end
  end

  # Mockups (plugins/mockups) has no in-app "create" action -- a mockup only
  # comes to exist via chat's show_preview MCP tool -- so the Mockups sidebar
  # page would otherwise be empty in every fresh preview. Seed one through the
  # same PreviewPanel::Service + Mockups::Mockup.record_publish! path the real
  # tool uses, guarded so re-running db:seed doesn't create a second copy.
  if Mockups::Mockup.where(user: demo_user).none?
    mockup_panel = PreviewPanel::Service.open!(
      chat_session: demo_chat,
      title: "Dashboard onboarding sketch",
      files: {
        "index.html" => "<!doctype html><html><body><h1>Dashboard onboarding sketch</h1></body></html>"
      }
    )
    Mockups::Mockup.record_publish!(
      panel: mockup_panel,
      user: demo_user,
      title: "Dashboard onboarding sketch",
      chat_session: demo_chat
    )
  end
end
