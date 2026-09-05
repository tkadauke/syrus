# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

Feature.find_or_create_by!(slug: "terminal") do |feature|
  feature.category = "labs"
  feature.name = "Terminal"
  feature.enabled = false
end

require_relative "seeds/themes"
Seeds::Themes.seed!

# Default any user still on no color theme (fresh migration, pre-EPIC-273
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
    last_message_at: Time.current
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
      diff_fixture: demo_diff_review_fixture
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
      diff_fixture: attrs[:diff_fixture]
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
end
