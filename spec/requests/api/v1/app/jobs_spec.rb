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

  before { sign_in_as(user) }

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

  def write_grade_log(run, name, contents)
    path = WorkflowWorkspace.path_for(run.workflow).join(".syrus", "grade-output", "iteration-#{run.iteration}", "#{name}.log")
    FileUtils.mkdir_p(path.dirname)
    path.write(contents)
  end

  it "lists jobs for bearer-token CLI clients without admin access" do
    user.update!(api_token: "syrus_cli_token", admin: false)
    job
    Factories.job(repository: Factories.repository(user: Factories.user, owner: "other", name: "repo"), issue_title: "Private")

    get "/api/v1/app/jobs", params: { repo: "acme/widgets", state: "all", limit: 5 },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["jobs"]).to contain_exactly(include(
      "id" => job.id,
      "title" => "Repair aqueduct",
      "repository_slug" => "acme/widgets",
      "pr_number" => 7
    ))
    expect(body.to_s).not_to include("Private")
  end

  it "returns the latest run transcript for CLI clients" do
    user.update!(api_token: "syrus_cli_token")
    run = job.initial_run
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "line one")
    run.job_logs.create!(sequence: 1, kind: "stdout", chunk: "line two")

    get "/api/v1/app/jobs/#{job.id}/transcript", headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "job_id" => job.id,
      "run_id" => run.id,
      "lines" => [ "line one", "line two" ]
    )
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
    run.run_health_snapshots.create!(run_state: "running", health_status: "healthy", log_count: 1)
    run.create_run_diagnostic!(error_class: "Timeout::Error", error_message: "too much marble")
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
      "display_number" => epic.display_number,
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
  end

  it "returns job detail cost after a run records cost metadata" do
    job.initial_run.update!(cost_usd: 0.34)

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("job", "total_cost_usd")).to eq(0.34)
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
      "logs_count" => 2
    )
    expect(body["logs"].map { |log| log.slice("sequence", "kind", "chunk") }).to eq([
      { "sequence" => 0, "kind" => "stdout", "chunk" => "first line" },
      { "sequence" => 1, "kind" => "stderr", "chunk" => "second line" }
    ])
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

    option_values = body["dependency_target_options"].map { |option| option.fetch("value") }
    option_labels = body["dependency_target_options"].map { |option| option.fetch("label") }.join("\n")
    expect(option_values).to include("issue:#{repo.id}:41", "job:#{direct_job.id}")
    expect(option_values).not_to include("job:#{older_issue_job.id}", "issue:#{repo.id}:42")
    expect(option_labels.scan("#41").size).to eq(1)
    expect(option_labels).to include("JOB-#{newer_issue_job.id}")
    expect(option_labels).to include("JOB-#{direct_job.id} - One-off cleanup")
    expect(option_labels).not_to include("Job ##{newer_issue_job.id}", "Job ##{direct_job.id}")
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
      "position" => 1,
      "blocked_reason" => "waiting for epic siblings to be approved"
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
end
