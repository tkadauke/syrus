require "rails_helper"
require "tmpdir"

RSpec.describe "App API job detail", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      repository: repo,
      issue_number: 42,
      issue_title: "Repair aqueduct",
      issue_body: "Water should go uphill, apparently.",
      branch_name: "syrus/issue-42",
      pr_number: 7,
      pr_mergeable: true,
      pr_mergeable_checked_at: Time.current
    )
  end

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

  before do
    allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
      RepoReconciliationPlan::Result.new(mode: "none", source: "test", note: nil)
    )
  end

  around do |example|
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir("syrus-app-api-jobs") do |data_root|
      ENV["SYRUS_DATA_ROOT"] = data_root
      example.run
    end
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
  end

  def parse_body = JSON.parse(response.body)
  def app_job_chat_feedback_path(job_record) = "/api/v1/app/jobs/#{job_record.id}/chat_feedback"

  def write_grade_log(run, name, contents)
    path = WorkflowWorkspace.path_for(run.workflow).join(".syrus", "grade-output", "iteration-#{run.iteration}", "#{name}.log")
    FileUtils.mkdir_p(path.dirname)
    path.write(contents)
  end

  it "lists jobs for bearer-token CLI clients without admin access" do
    user.update!(api_token: "syrus_cli_token", admin: false)
    epic = Factories.epic(user: user, repository: repo, title: "Raise the aqueduct")
    job
    job.update!(epic: epic)
    job.workflows.update_all(state: "succeeded")
    Factories.job(repository: Factories.repository(user: Factories.user, owner: "other", name: "repo"), issue_title: "Private")

    get "/api/v1/app/jobs", params: { repo: "acme/widgets", state: "all", limit: 5 },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["jobs"]).to contain_exactly(include(
      "id" => job.id,
      "epic_id" => epic.id,
      "epic_title" => "Raise the aqueduct",
      "title" => "Repair aqueduct",
      "issue_title" => "Repair aqueduct",
      "repository_id" => repo.id,
      "repository_slug" => "acme/widgets",
      "branch_name" => "syrus/issue-42",
      "pr_number" => 7
    ))
    expect(body.to_s).not_to include("Private")
  end

  it "includes epic_title for jobs with an epic and nil for epicless jobs" do
    user.update!(api_token: "syrus_cli_token")
    epic = Factories.epic(user: user, repository: repo, title: "Fix the pipes")
    with_epic = Factories.job_record(repository: repo, issue_number: 101, issue_title: "Epic job", state: "implemented")
    with_epic.update!(epic: epic)
    without_epic = Factories.job_record(repository: repo, issue_number: 102, issue_title: "Plain job", state: "implemented")

    get "/api/v1/app/jobs", params: { repo: "acme/widgets", state: "implemented", limit: 10 },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    jobs_payload = parse_body["jobs"]
    expect(jobs_payload.find { |j| j["id"] == with_epic.id }).to include("epic_title" => "Fix the pipes")
    expect(jobs_payload.find { |j| j["id"] == without_epic.id }).to include("epic_title" => nil)
  end

  it "includes latest_deployment_stage for compact jobs when stages are configured" do
    user.update!(api_token: "syrus_cli_token")
    staging = SyrusYml::DeploymentStage.new(name: "staging", label: "On Staging", tag: "staging", tag_pattern: nil)
    production = SyrusYml::DeploymentStage.new(name: "production", label: "In Production", tag: "production", tag_pattern: nil)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
    )
    landed = Factories.job_record(repository: repo, issue_number: 101, issue_title: "Deploy me", state: "implemented", landed_sha: "abc123")
    landed.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.zone.parse("2026-07-30T12:00:00Z"))

    get "/api/v1/app/jobs", params: { repo: "acme/widgets", state: "implemented", limit: 10 },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    payload = parse_body.fetch("jobs").find { |item| item.fetch("id") == landed.id }
    expect(payload.fetch("latest_deployment_stage")).to eq(
      "name" => "staging",
      "label" => "On Staging",
      "reached_at" => "2026-07-30T12:00:00Z"
    )
  end

  it "updates the job provider setting without rewriting existing workflow pins" do
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")
    old_workflow = job.latest_workflow
    old_workflow.update!(agent_provider: "claude")

    patch "/api/v1/app/jobs/#{job.id}/provider_setting",
      params: { job_provider_setting: "codex" },
      as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.job_provider_setting).to eq("codex")
    expect(job.agent_provider).to eq("claude")
    expect(old_workflow.reload.agent_provider).to eq("claude")
    expect(parse_body.dig("job", "agent_provider")).to eq("codex")
    expect(parse_body.dig("job", "job_provider_setting")).to eq("codex")
  end

  it "rejects unconfigured explicit job provider settings" do
    patch "/api/v1/app/jobs/#{job.id}/provider_setting",
      params: { job_provider_setting: "codex" },
      as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload.job_provider_setting).to eq("default")
  end

  it "hides jobs with active workflows from the app job list" do
    user.update!(api_token: "syrus_cli_token")
    idle = Factories.job_record(repository: repo, issue_number: 101, issue_title: "Ready", state: "implemented")
    active = Factories.job_record(repository: repo, issue_number: 102, issue_title: "Still running", state: "implemented")
    finished = Factories.job_record(repository: repo, issue_number: 103, issue_title: "Finished", state: "implemented")

    Workflow.create!(job: active, trigger_kind: "manual", state: "running")
    Workflow.create!(job: finished, trigger_kind: "manual", state: "succeeded")

    get "/api/v1/app/jobs", params: { repo: "acme/widgets", state: "implemented", limit: 10 },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    ids = parse_body.fetch("jobs").map { |payload| payload.fetch("id") }
    expect(ids).to contain_exactly(idle.id, finished.id)
  end

  it "returns the latest run transcript for CLI clients" do
    user.update!(api_token: "syrus_cli_token")
    run = job.initial_run
    run.start!
    run.succeed!
    run.save!
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "digging trench")
    run.job_logs.create!(sequence: 1, kind: "stdout", chunk: "water flows")

    get "/api/v1/app/jobs/#{job.id}/transcript", headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "job_id" => job.id,
      "run_id" => run.id,
      "state" => "succeeded",
      "complete" => true,
      "lines" => [ "digging trench", "water flows" ]
    )
  end

  it "creates a chat feedback workflow for an implemented job" do
    job.update!(state: "implemented")

    expect {
      post app_job_chat_feedback_path(job), params: { body: "Please tighten the copy." }, as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "chat_feedback").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "chat_feedback").last
    expect(response).to have_http_status(:created)
    expect(workflow.artifact("chat_feedback")).to eq("Please tighten the copy.")
    expect(parse_body).to include(
      "job" => include("id" => job.id, "state" => "implemented"),
      "workflow" => include("id" => workflow.id, "trigger_kind" => "chat_feedback")
    )
  end

  it "creates a chat feedback workflow for a failed job" do
    job.update!(state: "failed")

    expect {
      post app_job_chat_feedback_path(job), params: { body: "Recover from the failing run." }, as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "chat_feedback").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "chat_feedback").last
    expect(response).to have_http_status(:created)
    expect(workflow.artifact("chat_feedback")).to eq("Recover from the failing run.")
  end

  it "rejects blank chat feedback bodies" do
    job.update!(state: "implemented")

    expect {
      post app_job_chat_feedback_path(job), params: { body: " " }, as: :json
    }.not_to change { job.reload.workflows.where(trigger_kind: "chat_feedback").count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Feedback body can't be blank")
  end

  it "rejects chat feedback for jobs in the wrong state" do
    job.update!(state: "queued")

    expect {
      post app_job_chat_feedback_path(job), params: { body: "Please adjust this." }, as: :json
    }.not_to change { job.reload.workflows.where(trigger_kind: "chat_feedback").count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("queued jobs are not actionable")
  end

  it "requires authentication for chat feedback", :skip_sign_in do
    post app_job_chat_feedback_path(job), params: { body: "Please adjust this." }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it "does not expose another user's job for chat feedback" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)
    other_job.update!(state: "implemented")

    post app_job_chat_feedback_path(other_job), params: { body: "Please adjust this." }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_job.reload.workflows.where(trigger_kind: "chat_feedback")).to be_empty
  end

  it "returns a structured job detail payload for React rendering" do
    user.update!(admin: false)
    owner = Factories.user(email_address: "owner@example.com")
    job.update!(owner_user: owner)
    epic = Factories.epic(user: user, repository: repo, title: "Raise the aqueduct", state: "in_progress")
    job.update!(epic: epic)
    tag = Factories.tag(user: user, name: "priority:forum")
    job.job_tags.create!(tag: tag)
    target = Factories.job(repository: repo, issue_number: 41, issue_title: "Build hill")
    dependency = job.dependencies.create!(depends_on_job: target, source: "manual", created_by_user: user)
    attachment = job.job_attachments.create!(
      user: user,
      kind: "google_doc",
      title: "Roman hydraulics",
      google_doc_url: "https://docs.google.com/document/d/aqueduct/edit"
    )
    run = job.initial_run
    run.start!
    run.save!
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "digging trench")
    run.job_logs.create!(sequence: 1, kind: "rate_limited", chunk: "[rate-limited] core quota exhausted")
    run.run_health_snapshots.create!(run_state: "running", health_status: "stale", log_count: 0, created_at: 1.minute.ago, updated_at: 1.minute.ago)
    run.run_health_snapshots.create!(run_state: "running", health_status: "healthy", log_count: 1)
    run.create_run_diagnostic!(error_class: "Timeout::Error", error_message: "too much marble")
    run.command_spans.create!(
      job: job,
      workflow: run.workflow,
      step: run.step,
      sequence: 1,
      name: "bundle check",
      command_excerpt: "bundle check",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      duration_ms: 60_000,
      exit_status: 0,
      outcome: "succeeded",
      hostname: "worker-a"
    )
    run.create_run_failure_classification!(
      classification: "timeout",
      confidence: 0.8,
      retryable: true,
      reason: "The run failed because an operation timed out.",
      diagnostic_summary: "Timeout::Error: too much marble",
      classifier_inputs: { "error_class" => "Timeout::Error" },
      classified_at: Time.current
    )

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("job", "id")).to eq(job.id)
    expect(body.dig("job", "issue_title")).to eq("Repair aqueduct")
    expect(body.dig("job", "total_cost_usd")).to be_nil
    expect(body["job"]).to include(
      "owner_user_id" => owner.id,
      "owner_user" => include("id" => owner.id, "email_address" => "owner@example.com")
    )
    expect(body.dig("job", "pr_url")).to eq("https://github.com/acme/widgets/pull/7")
    expect(body.dig("job", "issue_url")).to eq("https://github.com/acme/widgets/issues/#{job.issue_number}")
    expect(body.dig("job", "retry_state")).to include(
      "classification" => nil,
      "classification_label" => "Unclassified",
      "state_label" => "No failure",
      "auto_retry_exhausted" => false
    )
    expect(body.dig("repository", "slug")).to eq("acme/widgets")
    expect(body["epic"]).to include(
      "id" => epic.id,
      "number" => epic.number,
      "display_number" => epic.slug,
      "title" => "Raise the aqueduct",
      "state" => "in_progress",
      "epic_path" => "/epics/#{epic.id}"
    )
    expect(body["pinned"]).to eq(false)
    expect(body["tags"]).to contain_exactly(include("id" => tag.id, "name" => "priority:forum"))
    expect(body["dependencies"]).to contain_exactly(include(
      "id" => dependency.id,
      "manual" => true,
      "depends_on_job" => include("id" => target.id, "repository_slug" => "acme/widgets")
    ))
    expect(body["attachments"]).to contain_exactly(include(
      "id" => attachment.id,
      "title" => "Roman hydraulics",
      "google_doc_url" => "https://docs.google.com/document/d/aqueduct/edit",
      "app_delete_path" => "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}"
    ))
    expect(body.dig("actions", "can_poll_feedback")).to eq(true)
    expect(body.dig("actions", "can_check_mergeability")).to eq(true)
    expect(body.dig("actions", "can_claim")).to eq(true)
    expect(body.dig("actions", "can_unclaim")).to eq(false)
    expect(body.dig("actions", "can_view_timeline")).to eq(false)
    expect(body.dig("actions", "can_manage_tags")).to eq(true)
    expect(body.dig("paths", "app_poll_feedback_path")).to eq("/api/v1/app/jobs/#{job.id}/poll_feedback")
    expect(body.dig("paths", "app_claim_path")).to eq("/api/v1/app/jobs/#{job.id}/claim")
    expect(body.dig("paths", "app_source_path")).to eq("/api/v1/app/jobs/#{job.id}/source")
    expect(body.dig("paths", "app_timeline_path")).to eq("/api/v1/app/jobs/#{job.id}/timeline")

    workflow = body["workflows"].first
    expect(workflow).to include("trigger_kind" => "initial")
    expect(workflow["app_retry_step_path"]).to eq("/api/v1/app/jobs/#{job.id}/workflows/#{workflow['id']}/retry_step")
    first_step = workflow["steps"].first
    expect(first_step["display_name"]).to be_present
    expect(first_step["display_status"]).to eq("running")
    future_step = workflow["steps"].find { |step| step["runs"].empty? && step["state"] == "queued" }
    expect(future_step).to include("display_status" => nil)
    first_run = workflow["steps"].flat_map { |step| step["runs"] }.find { |payload| payload["id"] == run.id }
    expect(first_run).to include(
      "state" => "running",
      "job_log_count" => 2,
      "rate_limited" => true,
      "can_stop" => true,
      "can_diagnose" => true,
      "app_artifacts_path" => "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts",
      "app_stop_path" => "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/stop"
    )
    expect(first_run["health_snapshots"]).to contain_exactly(include("health_status" => "healthy", "run_state" => "running"))
    expect(first_run["failure_classification"]).to include(
      "classification" => "timeout",
      "retryable" => true,
      "reason" => "The run failed because an operation timed out."
    )
    expect(first_run["failure_classification"]).not_to have_key("classifier_inputs")
    expect(first_run["run_diagnostic"]).to include("present" => true)
    expect(first_run["run_diagnostic"]).not_to have_key("error_message")
    expect(first_run["command_spans"]).to contain_exactly(include(
      "name" => "bundle check",
      "command_excerpt" => "bundle check",
      "outcome" => "succeeded",
      "hostname" => "worker-a"
    ))
    expect(first_run.dig("worker_health_correlation", "command_spans", 0, "name")).to eq("bundle check")
  end

  it "returns job detail cost after a run records cost metadata" do
    job.initial_run.update!(cost_usd: 0.34)

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("job", "total_cost_usd")).to eq(0.34)
  end

  it "returns a workflow-only job detail payload for live workflow refreshes" do
    run = job.initial_run
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "digging trench")
    run.job_logs.create!(sequence: 1, kind: "rate_limited", chunk: "[rate-limited] core quota exhausted")

    get "/api/v1/app/jobs/#{job.id}/workflows"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.keys).to contain_exactly("job", "workflows", "workflows_pagination", "feature_flags", "actions", "paths")
    expect(body.dig("job", "id")).to eq(job.id)
    first_run = body["workflows"].flat_map { |workflow| workflow["steps"] }.flat_map { |step| step["runs"] }.find { |payload| payload["id"] == run.id }
    expect(first_run).to include(
      "job_log_count" => 2,
      "rate_limited" => true
    )
  end

  it "links cron job details back to their scheduled task" do
    task = repo.scheduled_tasks.create!(
      user: user,
      name: "Update architecture",
      prompt: "Update ARCHITECTURE.md.",
      kind: "cron",
      cron_expression: "0 12 * * *"
    )
    cron_job = Factories.job_record(user: user, repository: repo, kind: "cron", issue_number: nil, scheduled_task: task)

    get "/api/v1/app/jobs/#{cron_job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("job", "scheduled_task")).to include(
      "id" => task.id,
      "name" => "Update architecture",
      "scheduled_task_path" => "/scheduled_tasks/#{task.id}"
    )
  end

  it "exposes classified auto-retry state for failed jobs" do
    workflow = job.latest_workflow
    workflow.update!(
      state: "failed",
      failure_count: 2,
      artifacts: {
        "failure_classification" => "transient_provider_error",
        "failure_retryable" => true,
        "next_auto_retry_at" => "2026-06-02T12:30:00Z",
        "provider_circuit_open" => true,
        "retry_delayed_until" => "2026-06-02T12:45:00Z",
        "retry_delay_reason" => "Claude queue is saturated"
      }
    )
    job.current_run.update!(state: "failed", finished_at: Time.current)

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("job", "retry_state")).to include(
      "classification" => "transient_provider_error",
      "classification_label" => "Transient provider error",
      "retryable" => true,
      "next_auto_retry_at" => "2026-06-02T12:30:00Z",
      "retry_attempt_count" => 2,
      "retry_budget_remaining" => AppSetting.max_job_failures - 2,
      "retry_budget" => AppSetting.max_job_failures,
      "auto_retry_exhausted" => false,
      "provider_circuit_open" => true,
      "retry_delayed_until" => "2026-06-02T12:45:00Z",
      "retry_delay_reason" => "Claude queue is saturated",
      "state_label" => "Provider circuit open"
    )
  end

  it "returns claim ownership in the job detail payload" do
    job.update!(claimed_by_user: user, claimed_at: Time.zone.parse("2026-06-03 05:40:00 UTC"))

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["job"]).to include(
      "claimed_at" => "2026-06-03T05:40:00Z",
      "claimed_by_current_user" => true,
      "claimed_by_user" => include(
        "id" => user.id,
        "display_name" => user.display_name,
        "profile_path" => "/profiles/#{user.id}"
      )
    )
    expect(parse_body["actions"]).to include(
      "can_claim" => false,
      "can_unclaim" => true
    )
  end

  it "claims and releases a job for the current user" do
    post "/api/v1/app/jobs/#{job.id}/claim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Job claimed.")
    expect(parse_body.dig("job", "claimed_by_user")).to include("id" => user.id, "profile_path" => "/profiles/#{user.id}")
    expect(parse_body.dig("job", "claimed_by_current_user")).to eq(true)
    expect(job.reload.claimed_by_user).to eq(user)
    expect(job.claimed_at).to be_present

    delete "/api/v1/app/jobs/#{job.id}/claim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Job released.")
    expect(parse_body.dig("job", "claimed_by_user")).to be_nil
    expect(parse_body.dig("job", "claimed_by_current_user")).to eq(false)
    expect(job.reload.claimed_by_user).to be_nil
    expect(job.claimed_at).to be_nil
  end

  it "does not release another user's claim" do
    teammate = Factories.user(email_address: "teammate@example.com")
    job.update!(claimed_by_user: teammate, claimed_at: Time.current)

    delete "/api/v1/app/jobs/#{job.id}/claim"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "message")).to eq("Only the current owner can release this claim.")
    expect(job.reload.claimed_by_user).to eq(teammate)
  end

  it "paginates workflows on the job detail payload" do
    job.workflows.destroy_all
    12.times do |index|
      Workflow.create!(
        job: job,
        trigger_kind: index.zero? ? "initial" : "retry",
        agent_provider: "codex",
        created_at: Time.current + index.minutes
      )
    end

    get "/api/v1/app/jobs/#{job.id}", params: { workflows_page: 2 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["workflows"].size).to eq(2)
    expect(body["workflows"].map { |workflow| workflow["id"] }).to eq(job.workflows.reorder(created_at: :desc, id: :desc).offset(10).pluck(:id))
    expect(body["workflows_pagination"]).to include(
      "page" => 2,
      "per_page" => 10,
      "total_workflows" => 12,
      "total_pages" => 2,
      "first_item" => 11,
      "last_item" => 12,
      "previous_path" => "/jobs/#{job.id}?tab=workflows&workflows_page=1",
      "next_path" => nil
    )
    expect(body.dig("job", "workflows_count")).to eq(12)
  end

  it "returns run transcript rows and agent diff as a separate artifact payload" do
    run = job.initial_run
    run.update!(agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'forum'\n")
    run.job_logs.create!(sequence: 1, kind: "stderr", chunk: "second line")
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "first line")

    get "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "job_id" => job.id,
      "run_id" => run.id,
      "agent_diff" => "diff --git a/app.rb b/app.rb\n+puts 'forum'\n",
      "agent_diff_bytes" => run.agent_diff.bytesize,
      "step_agent_diff" => nil,
      "logs_count" => 2
    )
    expect(body["logs"].map { |log| log.slice("sequence", "kind", "chunk") }).to eq([
      { "sequence" => 0, "kind" => "stdout", "chunk" => "first line" },
      { "sequence" => 1, "kind" => "stderr", "chunk" => "second line" }
    ])
  end

  it "returns step_agent_diff in artifact payload when present" do
    run = job.initial_run
    run.update!(
      agent_diff: "diff --git a/a.rb b/a.rb\n+line1\n+line2\n",
      step_agent_diff: "diff --git a/a.rb b/a.rb\n+line2\n"
    )

    get "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["step_agent_diff"]).to eq("diff --git a/a.rb b/a.rb\n+line2\n")
  end

  it "returns workflows in descending creation order" do
    initial_workflow = job.latest_workflow
    initial_workflow.update!(created_at: 2.hours.ago)
    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", created_at: 1.hour.ago)

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["workflows"].map { |workflow| workflow["id"] }).to eq([
      retry_workflow.id,
      initial_workflow.id
    ])
  end

  it "returns dependency panels and deduplicated dependency target options for React rendering" do
    older_issue_job = Job.create!(
      user: user,
      repository: repo,
      issue_number: 41,
      issue_title: "Old attempt"
    )
    newer_issue_job = Job.create!(
      user: user,
      repository: repo,
      issue_number: 41,
      issue_title: "Latest attempt"
    )
    direct_job = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "One-off cleanup",
      issue_body: "Tidy the thing."
    )
    target = Job.create!(user: user, repository: repo, issue_number: 42)
    JobDependency.create!(job: target, depends_on_job: newer_issue_job, source: "manual")
    older_issue_job.touch

    get "/api/v1/app/jobs/#{target.id}"

    body = parse_body
    expect(body["dependencies"]).to contain_exactly(include(
      "source" => "manual",
      "depends_on_job" => include("id" => newer_issue_job.id, "issue_number" => 41)
    ))
    expect(body["dependents"]).to eq([])

    expect(body["dependency_target_options"]).to eq([])
    expect(body["epic_dependency_target_options"]).to eq([])

    get "/api/v1/app/jobs/#{target.id}/dependency_options"

    options_body = parse_body
    option_values = options_body["dependency_target_options"].map { |option| option.fetch("value") }
    option_labels = options_body["dependency_target_options"].map { |option| option.fetch("label") }.join("\n")
    expect(option_values).to include("issue:#{repo.id}:41", "job:#{direct_job.id}")
    expect(option_values).not_to include("job:#{older_issue_job.id}", "issue:#{repo.id}:42")
    expect(option_labels.scan("#41").size).to eq(1)
    expect(option_labels).to include("#{newer_issue_job.slug}")
    expect(option_labels).to include("#{direct_job.slug} - One-off cleanup")
    expect(option_labels).not_to match(/Job\s+#(?:#{newer_issue_job.id}|#{direct_job.id})/)
    expect(option_labels).to include("Latest attempt")
    expect(option_labels).to include("One-off cleanup")

    get "/api/v1/app/jobs/#{newer_issue_job.id}"

    dependent = parse_body["dependents"].first
    expect(dependent).to include("source" => "manual")
    expect(dependent["job"]).to include("id" => target.id, "issue_number" => 42)
  end

  it "returns landing queue sibling blockers as clickable job targets" do
    repo.update!(auto_merge_enabled: true)
    epic = Factories.epic(user: user, repository: repo, state: "in_progress")
    job.update!(
      state: "approved",
      approved_at: Time.current,
      approved_via: "operator",
      epic: epic
    )
    job.workflows.update_all(state: "succeeded")
    sibling = Factories.job_record(
      user: user,
      repository: repo,
      epic: epic,
      issue_number: 43,
      issue_title: "Approve the sibling aqueduct",
      pr_number: 8,
      state: "implemented"
    )

    get "/api/v1/app/jobs/#{job.id}"

    entry = parse_body.fetch("landing_queue_entry")
    expect(entry).to include(
      "position" => nil,
      "blocked_reason" => { "key" => "waiting_epic_siblings" }
    )
    expect(entry.fetch("waiting_for_jobs")).to contain_exactly(
      include(
        "id" => sibling.id,
        "label" => "#43",
        "title" => "Approve the sibling aqueduct",
        "job_path" => "/jobs/#{sibling.id}"
      )
    )
  end

  it "lets admins force-fail an open job through the app API" do
    user.update!(admin: true)
    job.update!(state: "running")

    post "/api/v1/app/jobs/#{job.id}/force_fail"

    expect(response).to have_http_status(:ok)
    expect(job.reload.state).to eq("failed")
    expect(parse_body).to include(
      "message" => "Job force-failed.",
      "job" => include("id" => job.id, "state" => "failed")
    )
  end

  it "rejects app force-fail for non-admin users" do
    user.update!(admin: false)
    job.update!(state: "running")

    post "/api/v1/app/jobs/#{job.id}/force_fail"

    expect(response).to have_http_status(:forbidden)
    expect(job.reload.state).to eq("running")
  end

  it "returns admin-only diagnostic detail to admins" do
    user.update!(admin: true)
    run = job.initial_run
    diagnostic = run.create_run_diagnostic!(
      error_class: "RuntimeError",
      error_message: "broken chisel",
      error_backtrace: "app/work.rb:1",
      repo_snapshot: { "slug" => repo.slug }
    )
    run.create_run_failure_classification!(
      classification: "application_error",
      confidence: 0.4,
      retryable: false,
      reason: "The run failed with an unclassified application error.",
      classifier_inputs: { "error_class" => "RuntimeError" },
      classified_at: Time.current
    )

    get "/api/v1/app/jobs/#{job.id}"

    first_run = parse_body["workflows"].flat_map { |workflow| workflow["steps"] }.flat_map { |step| step["runs"] }.find { |payload| payload["id"] == run.id }
    expect(first_run["run_diagnostic"]).to include(
      "id" => diagnostic.id,
      "error_class" => "RuntimeError",
      "error_message" => "broken chisel",
      "error_backtrace" => "app/work.rb:1",
      "repo_snapshot" => { "slug" => "acme/widgets" }
    )
    expect(first_run["failure_classification"]).to include(
      "classification" => "application_error",
      "retryable" => false,
      "classifier_inputs" => { "error_class" => "RuntimeError" }
    )
  end

  it "returns a timeline payload separately from the detail payload" do
    user.update!(admin: true)
    run = job.initial_run
    run.start!
    run.fail!
    run.save!

    get "/api/v1/app/jobs/#{job.id}/timeline"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["job_id"]).to eq(job.id)
    expect(body["events"]).to include(
      include("source" => "workflow", "title" => include("created")),
      include("source" => "run", "title" => "Run ##{run.id} failed")
    )
    workflow_event = body["events"].find { |event| event["source"] == "workflow" }
    expect(workflow_event).to include(
      "at",
      "kind",
      "source",
      "title",
      "ref" => { "workflow_id" => job.latest_workflow.id },
      "ref_label" => "WF-#{job.latest_workflow.id}",
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{job.latest_workflow.id}"
    )
  end

  it "blocks timeline payloads for non-admin users" do
    user.update!(admin: false)

    get "/api/v1/app/jobs/#{job.id}/timeline"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "message")).to eq("Admin access required.")
  end

  it "returns grade logs as JSON for React rendering" do
    workflow = job.latest_workflow
    collect = workflow.steps.find_by!(kind: "grader_collect")
    collect.update!(position: collect.position + 1)
    grade_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: collect.position - 1,
      loop_id: collect.loop_id,
      iteration: collect.iteration,
      details: { "name" => "tests", "command" => "bin/rspec" }
    )
    grade_run = Run.create!(job: job, step: grade_step, trigger_kind: "initial", iteration: 1, state: "failed")
    grade_step.update!(state: "failed")
    write_grade_log(grade_run, "tests", "rspec output\n")

    get "/api/v1/app/jobs/#{job.id}"

    step_payload = parse_body["workflows"].flat_map { |payload| payload["steps"] }.find { |payload| payload["id"] == grade_step.id }
    expect(step_payload).to include("display_name" => "tests", "display_status" => "failed")
    run_payload = step_payload["runs"].find { |payload| payload["id"] == grade_run.id }
    expect(run_payload["app_grade_log_path"]).to include("/api/v1/app/jobs/#{job.id}/runs/#{grade_run.id}/grade_log", "name=tests")
    expect(run_payload).not_to have_key("grade_log_path")

    get "/api/v1/app/jobs/#{job.id}/runs/#{grade_run.id}/grade_log", params: { name: "tests" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "job_id" => job.id,
      "run_id" => grade_run.id,
      "name" => "tests",
      "contents" => "rspec output\n"
    )
  end

  it "returns grade logs from JobLog rows when the web process cannot see the worker workspace" do
    workflow = job.latest_workflow
    collect = workflow.steps.find_by!(kind: "grader_collect")
    collect.update!(position: collect.position + 1)
    grade_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: collect.position - 1,
      loop_id: collect.loop_id,
      iteration: collect.iteration,
      details: { "name" => "tests", "command" => "bin/rspec" }
    )
    grade_run = Run.create!(job: job, step: grade_step, trigger_kind: "initial", iteration: 1, state: "running")
    JobLog.append!(run: grade_run, chunk: "first chunk\n", kind: "grade_log")
    JobLog.append!(run: grade_run, chunk: "second chunk\n", kind: "grade_log")

    get "/api/v1/app/jobs/#{job.id}/runs/#{grade_run.id}/grade_log", params: { name: "tests" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "job_id" => job.id,
      "run_id" => grade_run.id,
      "name" => "tests",
      "contents" => "first chunk\nsecond chunk\n"
    )
  end

  it "falls back to the stored grader output excerpt after the workspace log is gone" do
    workflow = job.latest_workflow
    collect = workflow.steps.find_by!(kind: "grader_collect")
    collect.update!(position: collect.position + 1)
    grade_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: collect.position - 1,
      loop_id: collect.loop_id,
      iteration: collect.iteration,
      details: {
        "name" => "tests",
        "command" => "bin/rspec",
        "output" => "stored excerpt\n"
      }
    )
    grade_run = Run.create!(job: job, step: grade_step, trigger_kind: "initial", iteration: 1, state: "succeeded")

    get "/api/v1/app/jobs/#{job.id}/runs/#{grade_run.id}/grade_log", params: { name: "tests" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["contents"]).to eq("stored excerpt\n")
  end

  it "does not advertise a grade log link for the aggregate grader_collect step" do
    workflow = job.latest_workflow
    collect = workflow.steps.find_by!(kind: "grader_collect")
    collect_run = Run.create!(job: job, step: collect, trigger_kind: "initial", iteration: collect.iteration, state: "succeeded")

    get "/api/v1/app/jobs/#{job.id}"

    step_payload = parse_body["workflows"].flat_map { |payload| payload["steps"] }.find { |payload| payload["id"] == collect.id }
    run_payload = step_payload["runs"].find { |payload| payload["id"] == collect_run.id }
    expect(run_payload["app_grade_log_path"]).to be_nil
  end

  it "returns a JSON error when a grade log was pruned" do
    workflow = job.latest_workflow
    collect = workflow.steps.find_by!(kind: "grader_collect")
    collect.update!(position: collect.position + 1)
    grade_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: collect.position - 1,
      loop_id: collect.loop_id,
      iteration: collect.iteration,
      details: { "name" => "tests", "command" => "bin/rspec" }
    )
    grade_run = Run.create!(job: job, step: grade_step, trigger_kind: "initial", iteration: 1, state: "failed")

    get "/api/v1/app/jobs/#{job.id}/runs/#{grade_run.id}/grade_log", params: { name: "tests" }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "message")).to include("no longer available")
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    get "/api/v1/app/jobs/#{other_job.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "resolves a job by its human-readable slug" do
    # `job` has issue_title "Repair aqueduct", so its slug is "repair-aqueduct"
    get "/api/v1/app/jobs/#{job[:slug]}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("job", "id")).to eq(job.id)
  end

  it "returns 404 for an unknown job slug" do
    get "/api/v1/app/jobs/does-not-exist"

    expect(response).to have_http_status(:not_found)
  end

  describe "GET /api/v1/app/jobs/graph" do
    let(:job_a) { Factories.job_record(repository: repo, issue_number: 10, issue_title: "Alpha", state: "open") }
    let(:job_b) { Factories.job_record(repository: repo, issue_number: 11, issue_title: "Beta", state: "implemented") }
    let(:other_repo) { Factories.repository(user: Factories.user, owner: "other", name: "repo") }

    before { sign_in_as(user) }

    it "returns nodes and edges for all user jobs" do
      job_a
      job_b
      JobDependency.create!(job: job_b, depends_on_job: job_a, source: "manual")

      get "/api/v1/app/jobs/graph"

      expect(response).to have_http_status(:ok)
      body = parse_body
      node_ids = body["nodes"].map { |n| n["id"] }
      expect(node_ids).to include("job_#{job_a.id}", "job_#{job_b.id}")
      expect(body["edges"]).to contain_exactly(
        { "from_id" => "job_#{job_b.id}", "to_id" => "job_#{job_a.id}" }
      )
    end

    it "returns only nodes and no edges when jobs have no dependencies between them" do
      job_a
      job_b

      get "/api/v1/app/jobs/graph"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["nodes"].size).to eq(2)
      expect(body["edges"]).to be_empty
    end

    it "filters nodes by repository_id param" do
      job_a
      Factories.job_record(
        repository: Factories.repository(user: user, owner: "other", name: "repo2"),
        issue_title: "Other repo job",
        state: "open"
      )

      get "/api/v1/app/jobs/graph", params: { repository_id: repo.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      node_ids = body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_a.id}")
    end

    it "excludes edges that cross out of the filtered set" do
      job_a
      job_b
      JobDependency.create!(job: job_b, depends_on_job: job_a, source: "manual")
      q = Filters::QueryParam.encode({ "and" => [ { "field" => "state", "op" => "is", "value" => "implemented" } ] })

      get "/api/v1/app/jobs/graph", params: { q: q }

      expect(response).to have_http_status(:ok)
      body = parse_body
      node_ids = body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_b.id}")
      expect(body["edges"]).to be_empty
    end

    it "excludes jobs belonging to other users" do
      job_a
      other_user = Factories.user
      Factories.job_record(repository: Factories.repository(user: other_user, owner: "acme", name: "private"), issue_title: "Private")

      get "/api/v1/app/jobs/graph"

      body = parse_body
      node_ids = body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_a.id}")
    end

    it "includes kind, state, label, url, epic_id, and is_focal fields on each node" do
      job_a

      get "/api/v1/app/jobs/graph"

      node = parse_body["nodes"].first
      expect(node).to include(
        "id" => "job_#{job_a.id}",
        "kind" => "job",
        "state" => "open",
        "label" => "JOB-#{job_a.id} Alpha",
        "url" => "/jobs/JOB-#{job_a.id}",
        "epic_id" => nil,
        "is_focal" => false
      )
    end

    it "filters graph nodes by smart_folder_id" do
      job_a
      job_b
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Only implemented jobs",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "implemented" } ] }
      )

      get "/api/v1/app/jobs/graph", params: { smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      node_ids = body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_b.id}")
    end

    it "ignores a smart_folder_id belonging to another user" do
      job_a
      job_b
      other_user = Factories.user
      folder = SmartFolder.create!(
        user: other_user,
        subject_type: "job",
        name: "Private folder",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] }
      )

      get "/api/v1/app/jobs/graph", params: { smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      node_ids = parse_body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_a.id}", "job_#{job_b.id}")
    end

    it "applies a q param as a base64-encoded AST filter tree" do
      job_a
      job_b
      q = Filters::QueryParam.encode({ "and" => [ { "field" => "state", "op" => "is_not", "value" => "implemented" } ] })

      get "/api/v1/app/jobs/graph", params: { q: q }

      node_ids = parse_body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_a.id}")
    end

    it "suppresses smart folder filter when q filter is active" do
      job_a
      job_b
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Implemented only",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "implemented" } ] }
      )
      q = Filters::QueryParam.encode({ "and" => [ { "field" => "state", "op" => "is_not", "value" => "implemented" } ] })

      get "/api/v1/app/jobs/graph", params: { smart_folder_id: folder.id, q: q }

      node_ids = parse_body["nodes"].map { |n| n["id"] }
      expect(node_ids).to contain_exactly("job_#{job_a.id}")
    end
  end
end
