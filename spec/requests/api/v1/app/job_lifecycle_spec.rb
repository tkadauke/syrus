require "rails_helper"

RSpec.describe "App API job lifecycle commands", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(repository: repo, issue_number: 42) }

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

  def parse_body = JSON.parse(response.body)
  def app_job_path(job_record, action) = "/api/v1/app/jobs/#{job_record.id}/#{action}"

  it "starts an unstarted direct job" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Direct repair",
      issue_body: "Repair the forum."
    )

    expect {
      post app_job_path(direct, "start"), as: :json
    }.to change { direct.reload.runs.count }.from(0).to(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Initial workflow enqueued.")
    expect(parse_body.dig("job", "runs_count")).to eq(1)
    expect(parse_body.dig("paths", "job_path")).to eq(job_path(direct, tab: "workflows"))
  end

  it "reports a blocked reason instead of a false success when the initial workflow is admission-blocked" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Direct repair",
      issue_body: "Repair the forum."
    )
    decision = WorkflowAdmissionBudget::Decision.new(
      action: "delay_until",
      reason: "predicted_budget_pressure_high",
      pressure: { "projected" => { "cpu_pressure" => 105.0 } },
      delay_until: 10.minutes.from_now,
      override: false,
      details: { "candidate_seconds" => 1800 }
    )
    allow(WorkflowAdmissionBudget).to receive(:call).and_return(decision)

    expect {
      post app_job_path(direct, "start"), as: :json
    }.not_to change { direct.reload.runs.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq(
      "Blocked: workflow admission budget — see job card for details."
    )
    expect(direct.reload.workflows.where(trigger_kind: "initial").last.artifact("start_blocked_reason"))
      .to eq(StepDispatcher::ADMISSION_BLOCK_REASON)
  end

  it "retries a completed job" do
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }

    expect {
      post app_job_path(job, "run_again"), params: { retry_context: "Try the marble route." }, as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(response).to have_http_status(:ok)
    expect(workflow.artifacts["replay_context"]).to eq("Try the marble route.")
    expect(parse_body).to include("message" => "Retry workflow enqueued.")
    expect(parse_body.dig("paths", "job_path")).to eq(job_path(job, tab: "workflows"))
  end

  it "retries a completed job with another configured agent provider" do
    user.update!(claude_oauth_token: "claude-token", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    job.update!(agent_provider: "claude")
    job.initial_run.tap { |run| run.update!(agent_provider: "claude"); run.start!; run.succeed!; run.save! }
    job.latest_workflow.update!(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    expect {
      post app_job_path(job, "run_again"), params: { agent_provider: "codex" }, as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Retry workflow enqueued with Codex.")
    expect(job.reload.agent_provider).to eq("claude")
    expect(job.job_provider_setting).to eq("default")
    expect(workflow.agent_provider).to eq("codex")
    expect(workflow.first_step.runs.last.agent_provider).to eq("codex")
  end

  it "retries a completed job with bearer token auth when forgery protection is enabled", :skip_sign_in do
    token = user.generate_api_token!
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }

    previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    expect {
      post app_job_path(job, "run_again"), headers: { "Authorization" => "Bearer #{token}" }
    }.to change { job.reload.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)
  ensure
    ActionController::Base.allow_forgery_protection = previous_forgery_protection
  end

  it "restarts a job with a replacement job" do
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    original_id = job.id

    expect {
      post app_job_path(job, "restart"), as: :json
    }.to change(Job, :count).by(1)
      .and have_enqueued_job(RunJob)

    new_job = Job.where(repository_id: repo.id, issue_number: 42).order(:created_at).last
    expect(response).to have_http_status(:created)
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("replaced")
    expect(new_job.id).not_to eq(original_id)
    expect(parse_body.dig("job", "id")).to eq(new_job.id)
    expect(parse_body.dig("old_job", "id")).to eq(original_id)
    expect(parse_body["redirect_to"]).to eq(job_path(new_job))
  end

  it "restarts a direct job preserving kind, title, body, and agent_provider" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Tighten the bolts",
      issue_body: "Please tighten all the bolts.",
      agent_provider: "claude"
    )

    expect {
      post app_job_path(direct, "restart"), as: :json
    }.to change(Job, :count).by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:created)
    expect(direct.reload).to be_closed
    expect(direct.closure_reason).to eq("replaced")

    new_job = Job.order(:created_at).last
    expect(new_job.kind).to eq("direct")
    expect(new_job.issue_title).to eq("Tighten the bolts")
    expect(new_job.issue_body).to eq("Please tighten all the bolts.")
    expect(new_job.agent_provider).to eq("claude")
    expect(new_job.issue_number).to be_nil
  end

  it "rolls back the original job close when replacement creation fails" do
    # Corrupt the kind via update_columns (bypasses validations) so the replacement
    # job creation fails with RecordInvalid, exercising the transaction rollback path.
    job.update_columns(kind: "invalid_kind")

    post app_job_path(job, "restart"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload).to be_open
  end

  it "cancels active runs and closes the job" do
    run = job.initial_run
    run.start!
    run.save!

    post app_job_path(job, "cancel"), as: :json

    expect(response).to have_http_status(:ok)
    expect(run.reload).to be_cancelled
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("cancelled")
    expect(parse_body).to include("message" => "Cancellation requested.")
    expect(parse_body.dig("job", "state")).to eq("closed")
  end

  it "approves and unapproves an implemented job (self policy — owner is user)" do
    job.update!(state: "implemented")

    post app_job_path(job, "approve"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_approved
    expect(job.approved_via).to eq("operator")
    expect(job.approved_by_user).to eq(user)
    expect(parse_body).to include("message" => "Job approved.")
    expect(parse_body.dig("job", "approved_by_user_id")).to eq(user.id)
    expect(job.job_approvals.where(user: user).count).to eq(1)

    post app_job_path(job, "unapprove"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
    expect(job.approved_via).to be_nil
    expect(parse_body).to include("message" => "Job unapproved.")
  end

  it "records an approval vote without transitioning when policy is not yet satisfied (two_person)" do
    repo.update!(review_policy: "two_person")
    job.update!(state: "implemented", owner_user_id: user.id)

    post app_job_path(job, "approve"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_implemented
    expect(job.job_approvals.where(user: user).count).to eq(1)
    expect(parse_body).to include("message" => "Approval recorded.")
  end

  it "approves an implemented job with bearer token auth", :skip_sign_in do
    token = user.generate_api_token!
    job.update!(state: "implemented")

    post app_job_path(job, "approve"), headers: { "Authorization" => "Bearer #{token}" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_approved
    expect(job.approved_by_user).to eq(user)
    expect(parse_body).to include("message" => "Job approved.")
  end

  it "reapproves a landing failure and immediately dispatches landing" do
    repo.update!(approval_propagates_to_github: false)
    job.update!(
      state: "implemented",
      pr_number: 7,
      branch_name: "syrus/issue-42",
      landing_failure_reason: "auto_merge: PR mergeable_state is \"dirty\" and rebase cap reached"
    )
    job.latest_workflow.update!(state: "succeeded")
    job.initial_run.update_columns(state: "succeeded")

    expect {
      post app_job_path(job, "approve"), as: :json
    }.to change { job.reload.workflows.where(trigger_kind: "auto_merge").count }.by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_landing
    expect(job.landing_failure_reason).to be_nil
    expect(parse_body["message"]).to eq("Job approved. Landing workflow enqueued.")
    expect(parse_body.dig("job", "state")).to eq("landing")
  end

  it "rejects approval when auto-merge is disabled" do
    repo.update!(auto_merge_enabled: false)
    job.update!(state: "implemented")

    post app_job_path(job, "approve"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload).to be_implemented
    expect(parse_body.dig("error", "message")).to include("Auto-merge is disabled")
  end

  it "reopens a closed job" do
    job.close_with_reason!("cancelled")

    post app_job_path(job, "reopen"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_open
    expect(parse_body).to include("message" => "Thread reopened.")
    expect(parse_body.dig("job", "state")).to eq(job.state)
  end

  describe "local mode lifecycle" do
    let(:chat) { ChatSession.create!(user: user, mode: "local") }

    before { allow(Feature).to receive(:local_mode_enabled?).and_return(true) }

    it "opens an implemented job in local mode and links it to the chat" do
      implemented = Factories.job_record(repository: repo, state: "implemented", branch_name: "syrus/widget")

      post app_job_path(implemented, "open_in_local_mode"), params: { chat_id: chat.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(implemented.reload).to be_coding
      expect(implemented.linked_chat_id).to eq(chat.id)
      expect(parse_body).to include("message" => "Job opened in local mode. Continue in the linked chat.")
    end

    it "falls back to the most recent local mode chat when chat_id is omitted" do
      implemented = Factories.job_record(repository: repo, state: "implemented", branch_name: "syrus/widget")
      chat # ensure it exists

      post app_job_path(implemented, "open_in_local_mode"), as: :json

      expect(response).to have_http_status(:ok)
      expect(implemented.reload.linked_chat_id).to eq(chat.id)
    end

    it "returns 422 when no local mode chat exists" do
      implemented = Factories.job_record(repository: repo, state: "implemented")

      post app_job_path(implemented, "open_in_local_mode"), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("No active Local Mode chat")
    end

    it "returns 422 when the job is not implemented or approved" do
      running = Factories.job_record(repository: repo, state: "running")

      post app_job_path(running, "open_in_local_mode"), params: { chat_id: chat.id }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "cancels local mode for a taken-over job (has pr) returning it to implemented" do
      coding = Factories.job_record(repository: repo, state: "implemented", pr_number: 42)
      coding.update_columns(state: "coding", linked_chat_id: chat.id)

      post app_job_path(coding, "cancel_local_mode"), as: :json

      expect(response).to have_http_status(:ok)
      expect(coding.reload).to be_implemented
      expect(coding.linked_chat_id).to be_nil
    end

    it "closes a new coding job (no pr) when cancelling local mode" do
      coding = Factories.job_record(repository: repo, state: "running", kind: "direct", issue_number: nil)
      coding.update_columns(state: "coding", linked_chat_id: chat.id, pr_number: nil)

      post app_job_path(coding, "cancel_local_mode"), as: :json

      expect(response).to have_http_status(:ok)
      expect(coding.reload).to be_closed
      expect(coding.closure_reason).to eq("local_mode_cancelled")
    end

    it "returns 422 when cancelling local mode on a non-coding job" do
      implemented = Factories.job_record(repository: repo, state: "implemented")

      post app_job_path(implemented, "cancel_local_mode"), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 403 when local mode feature is disabled" do
      allow(Feature).to receive(:local_mode_enabled?).and_return(false)
      implemented = Factories.job_record(repository: repo, state: "implemented")

      post app_job_path(implemented, "open_in_local_mode"), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    post app_job_path(other_job, "cancel"), as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_job.reload).to be_open
  end

  it "resolves a job by its human-readable slug for lifecycle actions" do
    slugged_job = Factories.job(
      repository: repo,
      issue_number: 99,
      issue_title: "Repair the forum floor"
    )
    slugged_job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }

    expect {
      post "/api/v1/app/jobs/#{slugged_job[:slug]}/run_again", as: :json
    }.to change { slugged_job.reload.workflows.where(trigger_kind: "retry").count }.by(1)

    expect(response).to have_http_status(:ok)
  end
end
