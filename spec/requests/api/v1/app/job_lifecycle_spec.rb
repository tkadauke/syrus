require "rails_helper"

RSpec.describe "App API job lifecycle commands", :ci_only, type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(repository: repo, issue_number: 42) }

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

  def parse_body = JSON.parse(response.body)
  def app_job_path(job_record, action) = "/api/v1/app/jobs/#{job_record.id}/#{action}"
  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def finish_work_units_for(job_record)
    WorkUnit
      .joins(:work_unit_members)
      .where(work_unit_members: { job_id: job_record.id })
      .find_each { |unit| unit.mark_terminal!("succeeded") }
  end

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
    expect(direct.workflows.last.work_unit).to be_present
    expect(parse_body).to include("message" => "Initial workflow enqueued.")
    expect(parse_body.dig("job", "runs_count")).to eq(1)
    expect(parse_body.dig("paths", "job_path")).to eq(job_path(direct, tab: "workflows"))
  end

  it "does not preload historical workflows or runs for lifecycle responses" do
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    job.update!(state: "failed")
    finish_work_units_for(job)
    3.times do
      workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "failed")
      step = workflow.steps.create!(kind: "implement", position: 1, state: "failed")
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider, state: "failed")
    end

    queries = capture_sql do
      post app_job_path(job, "run_again"), as: :json
    end

    expect(response).to have_http_status(:ok)
    normalized_queries = queries.map { |sql| sql.squish }
    broad_workflow_preload = /SELECT\s+["`]?workflows["`]?\.\*\s+FROM\s+["`]?workflows["`]?\s+WHERE\s+["`]?workflows["`]?\.[ "`]?job_id["`]?\s*=\s*\?\z/i
    broad_run_preload = /SELECT\s+["`]?runs["`]?\.\*\s+FROM\s+["`]?runs["`]?\s+WHERE\s+["`]?runs["`]?\.[ "`]?job_id["`]?\s*=\s*\?\z/i

    expect(normalized_queries).not_to include(match(broad_workflow_preload))
    expect(normalized_queries).not_to include(match(broad_run_preload))
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
    blocked_workflow = direct.reload.workflows.where(trigger_kind: "initial").last
    expect(WorkUnits::StartBlock.for(blocked_workflow).reason).to eq("admission_control")
  end

  it "releases a backlogged direct job through normal initial admission" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      issue_number: nil,
      issue_title: "Planned repair",
      issue_body: "Repair the forum."
    )

    expect {
      post app_job_path(direct, "release_from_backlog"), as: :json
    }.to change { direct.reload.workflows.count }.from(0).to(1)
      .and change { direct.runs.count }.from(0).to(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(direct).to be_queued
    expect(parse_body).to include("message" => "Job released from backlog.")
    expect(parse_body.dig("job", "runs_count")).to eq(1)
    expect(parse_body.dig("paths", "job_path")).to eq(job_path(direct, tab: "workflows"))
  end

  it "does not release a job that is not backlogged" do
    expect {
      post app_job_path(job, "release_from_backlog"), as: :json
    }.not_to change { job.reload.workflows.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Only backlogged Jobs can be released.")
  end

  it "lets a write-tier repository member release a dependency-blocked backlogged job without starting a run" do
    writer = Factories.user
    RepositoryMembership.create!(repository: repo, user: writer, role: "write")
    prerequisite = Factories.job_record(user: user, repository: repo, issue_number: 50, state: "queued")
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      issue_number: nil,
      issue_title: "Blocked planned repair",
      issue_body: "Repair the forum."
    )
    JobDependency.create!(job: direct, depends_on_job: prerequisite, source: "manual")
    sign_in_as(writer)

    expect {
      post app_job_path(direct, "release_from_backlog"), as: :json
    }.to change { direct.reload.workflows.count }.from(0).to(1)
      .and change { direct.runs.count }.by(0)

    expect(response).to have_http_status(:ok)
    expect(direct).to be_queued
    expect(WorkUnits::StartBlock.for(direct.workflows.last).reason).to eq(StepDispatcher::STACK_BLOCK_REASON)
  end

  it "releases a backlogged job to triage without creating work when triage checks have not passed" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      validity: "duplicate",
      issue_number: nil,
      issue_title: "Needs triage",
      issue_body: "Hold until triaged."
    )

    expect {
      post app_job_path(direct, "release_from_backlog"), as: :json
    }.to change { direct.reload.state }.from("backlog").to("triaging")
      .and change { direct.workflows.count }.by(0)
      .and change { direct.runs.count }.by(0)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Job released from backlog.")
  end

  it "rejects release from backlog for read-tier repository members" do
    reader = Factories.user
    RepositoryMembership.create!(repository: repo, user: reader, role: "read")
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      issue_number: nil,
      issue_title: "Planned repair",
      issue_body: "Repair the forum."
    )
    sign_in_as(reader)

    post app_job_path(direct, "release_from_backlog"), as: :json

    expect(response).to have_http_status(:forbidden)
    expect(direct.reload).to be_backlog
  end

  it "cancels a backlogged job without creating a Workflow/Run and closes it with the cancelled reason" do
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      issue_number: nil,
      issue_title: "Planned repair",
      issue_body: "Repair the forum."
    )

    expect {
      post app_job_path(direct, "cancel"), as: :json
    }.not_to change { direct.reload.workflows.count }
    expect(direct.runs.count).to eq(0)

    expect(response).to have_http_status(:ok)
    expect(direct.reload).to be_closed
    expect(direct.closure_reason).to eq("cancelled")
    expect(parse_body).to include("message" => "Cancellation requested.")
  end

  it "rejects cancel for a backlogged job from a read-tier repository member" do
    reader = Factories.user
    RepositoryMembership.create!(repository: repo, user: reader, role: "read")
    direct = Job.create!(
      user: user,
      repository: repo,
      kind: "direct",
      state: "backlog",
      issue_number: nil,
      issue_title: "Planned repair",
      issue_body: "Repair the forum."
    )
    sign_in_as(reader)

    post app_job_path(direct, "cancel"), as: :json

    expect(response).to have_http_status(:forbidden)
    expect(direct.reload).to be_backlog
  end

  it "moves early jobs with no runtime or PR back to backlog" do
    early = Factories.job_record(repository: repo, issue_number: 60, state: "needs_triage")

    post app_job_path(early, "move_to_backlog"), as: :json

    expect(response).to have_http_status(:ok)
    expect(early.reload).to be_backlog
    expect(parse_body).to include("message" => "Job moved to backlog.")
  end

  it "rejects moving post-PR jobs back to backlog" do
    implemented = Factories.job_record(repository: repo, issue_number: 61, state: "implemented", pr_number: 17)

    post app_job_path(implemented, "move_to_backlog"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(implemented.reload).to be_implemented
  end

  it "rejects moving jobs with active runtime work back to backlog" do
    active = Factories.job_record(repository: repo, issue_number: 62, state: "queued")
    workflow = Workflow.create!(job: active, trigger_kind: "initial", state: "running")
    attach_work_unit(workflow, member_jobs: [ active ], state: "running")

    post app_job_path(active, "move_to_backlog"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(active.reload).to be_queued
  end

  # A Job the classifier could not place waits on a person, not on Syrus.
  # Before these, `classifier_uncertain` had no exit at all: the classifier
  # refused to re-run, the reconciler did not see it, and nothing surfaced it.
  describe "triage decisions" do
    let(:uncertain) do
      Factories.job_record(repository: repo, issue_number: 70).tap do |record|
        record.update_columns(state: "triaging", triaging_reason: "classifier_uncertain",
                              triaging_uncertainty_reason: "invalid JSON: expected an object")
      end
    end

    it "queues the job for work when accepted" do
      post app_job_path(uncertain, "accept_triage"), as: :json

      expect(response).to have_http_status(:ok)
      expect(uncertain.reload).to be_queued
      expect(uncertain.triaging_uncertainty_reason).to be_nil
    end

    # `cancelled`, not one of the successful reasons: rejecting an unclear
    # request delivers nothing, and filing it as a success would corrupt the
    # attribution closure reasons exist to keep honest.
    it "closes the job as cancelled when rejected" do
      post app_job_path(uncertain, "reject_triage"), as: :json

      expect(response).to have_http_status(:ok)
      expect(uncertain.reload).to be_closed
      expect(uncertain.closure_reason).to eq("cancelled")
    end

    it "refuses either decision for a job that is not awaiting triage" do
      post app_job_path(job, "accept_triage"), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    # Parking an unclassified Job in the backlog moves it from one place
    # nothing acts on to another; Accept or Reject is the real decision.
    it "does not offer Move to backlog while a job is in triage" do
      payload = App::JobDetailPayload.new(job: uncertain, user: user).payload

      expect(payload[:actions][:can_move_to_backlog]).to be_falsey
      expect(payload[:actions][:can_accept_triage]).to be(true)
      expect(payload[:actions][:can_reject_triage]).to be(true)
    end
  end

  it "retries a completed job" do
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    finish_work_units_for(job)

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
    finish_work_units_for(job)

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
    finish_work_units_for(job)

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

  it "preserves epic membership when restarting an issue-kind job that belongs to an epic" do
    epic = Factories.epic(user: user, repository: repo)
    job.update!(epic: epic)
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }

    expect {
      post app_job_path(job, "restart"), as: :json
    }.to change(Job, :count).by(1)

    new_job = Job.where(repository_id: repo.id, issue_number: 42).order(:created_at).last
    expect(response).to have_http_status(:created)
    expect(new_job.epic_id).to eq(epic.id)
  end

  it "rewires dependent job dependencies to point at the replacement job when restarted" do
    dependent = Factories.job(repository: repo, issue_number: 43)
    dependency = dependent.dependencies.create!(depends_on_job: job, source: "manual")
    job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }

    expect {
      post app_job_path(job, "restart"), as: :json
    }.to change(Job, :count).by(1)

    new_job = Job.where(repository_id: repo.id, issue_number: 42).order(:created_at).last
    expect(response).to have_http_status(:created)
    expect(dependency.reload.depends_on_job_id).to eq(new_job.id)
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

  it "stops landing without closing the job" do
    job.update!(state: "implemented")
    job.approve!(via: "operator")
    job.start_landing!
    job.save!

    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running", started_at: 5.minutes.ago)
    intent = WorkIntent.create!(
      kind: "auto_merge", state: "requested", repository: repo,
      scope_type: "job", scope_id: job.id, actor: user, source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent, kind: "auto_merge", state: "running",
      repository: repo, scope_type: "job", scope_id: job.id, workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")

    post app_job_path(job, "stop_landing"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_implemented
    expect(job).to be_open
    expect(workflow.reload).to be_cancelled
    expect(parse_body).to include("message" => "Landing stopped.")
    expect(parse_body.dig("job", "state")).to eq("implemented")
  end

  it "rejects stop_landing when the job is not landing" do
    job.update!(state: "implemented")

    post app_job_path(job, "stop_landing"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload).to be_implemented
  end

  it "approves and unapproves an implemented job (self policy — owner is user)" do
    job.update!(state: "implemented")
    job.initial_run.update_columns(state: "succeeded")
    finish_work_units_for(job)

    post app_job_path(job, "approve"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_approved
    expect(job.approved_via).to eq("operator")
    expect(job.approved_by_user).to eq(user)
    expect(parse_body).to include("message" => "Job approved.")
    expect(parse_body.dig("job", "approved_by_user_id")).to eq(user.id)
    expect(job.job_approvals.where(user: user).count).to eq(1)
    # can_approve/can_unapprove must flip in the same response as the state
    # change so the frontend can update the button and the badge together,
    # instead of the Approve button lingering until the next full refetch.
    expect(parse_body.dig("actions", "can_approve")).to be(false)
    expect(parse_body.dig("actions", "can_unapprove")).to be(true)

    post app_job_path(job, "unapprove"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
    expect(job.approved_via).to be_nil
    expect(parse_body).to include("message" => "Job unapproved.")
    expect(parse_body.dig("actions", "can_approve")).to be(true)
    expect(parse_body.dig("actions", "can_unapprove")).to be(false)
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
    finish_work_units_for(job)

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

  describe "approve/run_again/cancel with a repository member who does not own the job" do
    let(:read_member) { Factories.user }
    let(:write_member) { Factories.user }

    before do
      repo.repository_memberships.create!(user: read_member, role: "read")
      repo.repository_memberships.create!(user: write_member, role: "write")
    end

    it "403s cancel for a read-tier member" do
      sign_in_as(read_member)

      post app_job_path(job, "cancel"), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.reload).to be_open
    end

    it "allows cancel for a write-tier member" do
      sign_in_as(write_member)

      post app_job_path(job, "cancel"), as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload).to be_closed
    end

    it "403s stop_landing for a read-tier member" do
      job.update!(state: "implemented")
      job.approve!(via: "operator")
      job.start_landing!
      job.save!
      sign_in_as(read_member)

      post app_job_path(job, "stop_landing"), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.reload).to be_landing
    end

    it "allows stop_landing for a write-tier member" do
      job.update!(state: "implemented")
      job.approve!(via: "operator")
      job.start_landing!
      job.save!
      sign_in_as(write_member)

      post app_job_path(job, "stop_landing"), as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload).to be_implemented
    end

    it "403s approve for a read-tier member" do
      job.update!(state: "implemented")
      sign_in_as(read_member)

      post app_job_path(job, "approve"), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(job.job_approvals).to be_empty
    end

    it "allows approve for a write-tier member (recorded as a vote, self policy still needs the owner)" do
      job.update!(state: "implemented")
      sign_in_as(write_member)

      post app_job_path(job, "approve"), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("message" => "Approval recorded.")
      expect(job.job_approvals.where(user: write_member).count).to eq(1)
      expect(job.reload).to be_implemented
    end

    it "403s run_again for a read-tier member" do
      job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
      finish_work_units_for(job)
      sign_in_as(read_member)

      post app_job_path(job, "run_again"), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "allows run_again for a write-tier member" do
      job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
      finish_work_units_for(job)
      sign_in_as(write_member)

      expect {
        post app_job_path(job, "run_again"), as: :json
      }.to change { job.reload.workflows.where(trigger_kind: "retry").count }.by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  it "resolves a job by its human-readable slug for lifecycle actions" do
    slugged_job = Factories.job(
      repository: repo,
      issue_number: 99,
      issue_title: "Repair the forum floor"
    )
    slugged_job.initial_run.tap { |run| run.start!; run.succeed!; run.save! }
    finish_work_units_for(slugged_job)

    expect {
      post "/api/v1/app/jobs/#{slugged_job[:slug]}/run_again", as: :json
    }.to change { slugged_job.reload.workflows.where(trigger_kind: "retry").count }.by(1)

    expect(response).to have_http_status(:ok)
  end
end
