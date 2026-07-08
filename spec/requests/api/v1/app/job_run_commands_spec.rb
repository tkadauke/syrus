require "rails_helper"

RSpec.describe "App API job run commands", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repo, issue_number: 42) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def app_job_path(path) = "/api/v1/app/jobs/#{job.id}#{path}"

  it "checks PR feedback for an open job with a PR" do
    job.update!(pr_number: 42)

    expect {
      post app_job_path("/poll_feedback"), as: :json
    }.to have_enqueued_job(PollPullRequestJob).with(job.id, manual: true)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Checking PR feedback now...")
    expect(parse_body.dig("job", "pr_number")).to eq(42)
  end

  it "switches to a configured agent before checking PR feedback" do
    user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    job.update!(pr_number: 42, agent_provider: "claude")

    expect {
      post app_job_path("/poll_feedback"), params: { agent_provider: "codex" }, as: :json
    }.to have_enqueued_job(PollPullRequestJob).with(job.id, manual: true, agent_provider: "codex")

    expect(response).to have_http_status(:ok)
    expect(job.reload.agent_provider).to eq("codex")
    expect(parse_body).to include("message" => "Checking PR feedback with Codex now...")
  end

  it "rejects an unconfigured selected feedback agent" do
    user.update!(claude_oauth_token: "oat-test", codex_api_key: nil)
    job.update!(pr_number: 42, agent_provider: "claude")

    expect {
      post app_job_path("/poll_feedback"), params: { agent_provider: "codex" }, as: :json
    }.not_to have_enqueued_job(PollPullRequestJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload.agent_provider).to eq("claude")
    expect(parse_body.dig("error", "message")).to eq("That agent is not configured.")
  end

  it "queues a mergeability check for jobs with managed or external PRs" do
    job.update!(external_pr_number: 99)

    expect {
      post app_job_path("/check_mergeability"), as: :json
    }.to have_enqueued_job(PollRebaseJob).with(job.id, bypass_cache: true)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Checking mergeability now...")
  end

  it "queues a rebase workflow when the job has a PR" do
    job.update!(pr_number: 7, branch_name: "syrus/issue-42-1")

    expect {
      post app_job_path("/rebase"), as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "rebase").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "rebase").last
    expect(response).to have_http_status(:ok)
    expect(workflow.first_step.runs.last).to be_present
    expect(parse_body).to include("message" => "Rebase workflow enqueued.")
    expect(parse_body.dig("workflow", "id")).to eq(workflow.id)
  end

  it "does not stack rebase workflows" do
    job.update!(pr_number: 7)
    workflow = Workflows::Rebase.instantiate(job: job)
    workflow.first_step.runs.create!(job: job, trigger_kind: "rebase", agent_provider: job.agent_provider)

    expect {
      post app_job_path("/rebase"), as: :json
    }.not_to change { job.reload.workflows.where(trigger_kind: "rebase").count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("already in progress")
  end

  it "resumes a failed run using its captured agent session" do
    failed_run = job.initial_run
    failed_run.start!
    failed_run.fail!
    failed_run.save!
    failed_run.step.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
    failed_run.step.workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
    ClaudeSession.create!(
      resumable: failed_run,
      provider: "codex",
      session_id: "uuid-deadbeef",
      transcript_jsonl: "{}\n"
    )
    workflow_count = job.reload.workflows.count

    expect {
      post app_job_path("/resume"), params: { source_run_id: failed_run.id }, as: :json
    }.to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(job.reload.workflows.count).to eq(workflow_count)
    run = Run.find(parse_body.dig("run", "id"))
    expect(run.parent_session_id).to eq("uuid-deadbeef")
    expect(parse_body).to include("message" => "Resume workflow enqueued.")
  end

  it "rejects resume when the source run has no captured session" do
    failed_run = job.initial_run
    failed_run.start!
    failed_run.fail!
    failed_run.save!

    expect {
      post app_job_path("/resume"), params: { source_run_id: failed_run.id }, as: :json
    }.not_to change { Workflow.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("No agent session captured")
  end

  it "stops an active run without closing the job" do
    run = job.initial_run
    run.start!
    run.save!

    post app_job_path("/runs/#{run.id}/stop"), as: :json

    expect(response).to have_http_status(:ok)
    expect(run.reload).to be_cancelled
    expect(job.reload).to be_open
    expect(parse_body).to include("message" => "Run stopped.")
    expect(parse_body.dig("run", "state")).to eq("cancelled")
  end

  it "rejects stopping a terminal run" do
    run = job.initial_run
    run.start!
    run.succeed!
    run.save!

    post app_job_path("/runs/#{run.id}/stop"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(run.reload).to be_succeeded
    expect(parse_body.dig("error", "message")).to eq("Run is not active.")
  end

  it "retries the failed step in a failed workflow" do
    workflow = job.workflows.last
    failed_step = workflow.steps.find_by!(kind: "summarize")
    failed_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "failed",
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    failed_step.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
    workflow.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)

    expect {
      post app_job_path("/workflows/#{workflow.id}/retry_step"), as: :json
    }.to change { failed_step.reload.runs.count }.by(1)
      .and have_enqueued_job(RunJob)

    new_run = failed_step.runs.order(:created_at).last
    expect(response).to have_http_status(:ok)
    expect(workflow.reload).to be_running
    expect(job.reload).to be_running
    expect(failed_step.reload).to be_queued
    expect(new_run.agent_provider).to eq(workflow.agent_provider)
    expect(parse_body).to include("message" => "Retrying summarize for WF-#{workflow.id}...")
    expect(parse_body.dig("job", "state")).to eq("running")
  end

  it "queues a push for a failed workflow with an intact workspace" do
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      agent_provider: job.agent_provider,
      state: "failed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )

    expect {
      post app_job_path("/workflows/#{workflow.id}/push_commits"), as: :json
    }.to have_enqueued_job(PushPendingCommitsJob).with(workflow.id)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Pushing commits to GitHub...")
    expect(parse_body.dig("workflow", "id")).to eq(workflow.id)
  end

  it "discards stale branch output from a diverged workflow" do
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      agent_provider: job.agent_provider,
      state: "failed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )
    workflow.set_artifact!("branch_divergence", {
      "branch" => "syrus/issue-42-#{job.id}",
      "remote_sha" => "remote-sha",
      "local_sha" => "local-sha"
    })
    job.update!(state: "failed", pr_number: 42)

    post app_job_path("/workflows/#{workflow.id}/discard_branch_output"), as: :json

    expect(response).to have_http_status(:ok)
    expect(workflow.reload.artifact("branch_divergence_recovery")).to include("action" => "discarded")
    expect(job.reload).to be_implemented
    expect(parse_body).to include("message" => "Discarded this workflow's stale branch output.")
    expect(parse_body.dig("workflow", "id")).to eq(workflow.id)
  end

  it "queues a diagnostic for an active run" do
    run = job.initial_run

    expect {
      post app_job_path("/runs/#{run.id}/diagnose"), as: :json
    }.to have_enqueued_job(DiagnoseRunJob).with(run.id)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Diagnostic queued - snapshot will appear shortly.")
    expect(parse_body.dig("run", "id")).to eq(run.id)
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    post "/api/v1/app/jobs/#{other_job.id}/poll_feedback", as: :json

    expect(response).to have_http_status(:not_found)
  end
end
