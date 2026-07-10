require "rails_helper"

RSpec.describe ChatPendingAction do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def direct_job(**attrs)
    Job.create!({
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Manual job",
      issue_body: "Do the thing."
    }.merge(attrs))
  end

  it "can reject a pending action without applying it" do
    job = Factories.job(repository: repository)
    action = chat_session.pending_actions.create!(
      action: "cancel_job",
      payload: { "job_id" => job.id }
    )

    expect(action.reject!).to be true
    expect(action.reload).to be_rejected
    expect(job.reload).to be_open
  end

  it "broadcasts a pending_action_updated event after creation" do
    expected_user = user
    expect(AppEvents).to receive(:broadcast) do |user:, type:, resource:, id:, changed:, payload:|
      expect(user).to eq(expected_user)
      expect(type).to eq("updated")
      expect(resource).to eq("chat")
      expect(id).to eq(chat_session.id)
      expect(changed).to eq([ "pending_action_updated" ])
      expect(payload).to include(
        action: "pending_action_updated",
        chat_message_id: nil,
        state: "pending"
      )
      expect(payload[:pending_action_id]).to be_a(Integer)
    end

    chat_session.pending_actions.create!(
      action: "pause_landing_queue",
      payload: {}
    )
  end

  it "broadcasts pending_action_updated events after terminal state changes" do
    allow(AppEvents).to receive(:broadcast)
    action = chat_session.pending_actions.create!(
      action: "pause_landing_queue",
      payload: {}
    )
    message = chat_session.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Confirm?" })

    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "pending_action_updated" ],
      payload: {
        action: "pending_action_updated",
        pending_action_id: action.id,
        chat_message_id: message.id,
        state: "rejected"
      }
    )

    action.reject!
  end

  it "promotes a queued action to pending and broadcasts the chat update" do
    allow(AppEvents).to receive(:broadcast)
    job = direct_job(state: "running")
    action = chat_session.pending_actions.create!(
      action: "submit_chat_feedback",
      state: "queued",
      payload: { "job_id" => job.id, "feedback" => "Please tighten this." }
    )

    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "pending_action_updated" ],
      payload: {
        action: "pending_action_updated",
        pending_action_id: action.id,
        chat_message_id: nil,
        state: "pending"
      }
    )

    expect(action.promote!).to be true
    expect(action.reload).to be_pending
  end

  it "cancels a queued action without requiring an operator user" do
    job = direct_job(state: "running")
    action = chat_session.pending_actions.create!(
      action: "submit_chat_feedback",
      state: "queued",
      payload: { "job_id" => job.id, "feedback" => "Please tighten this." }
    )

    expect(action.cancel!).to be true
    expect(action.reload).to be_cancelled
  end

  it "requires queued actions to be job scoped" do
    action = chat_session.pending_actions.build(
      action: "submit_chat_feedback",
      state: "queued",
      payload: { "feedback" => "Please tighten this." }
    )

    expect(action).not_to be_valid
    expect(action.errors[:payload]).to include("job_id is required")
  end

  it "keeps existing state enum values valid when adding queued" do
    expect(described_class.states.keys).to eq(%w[queued pending confirmed rejected cancelled])
    %w[pending confirmed rejected cancelled].each do |state|
      action = chat_session.pending_actions.build(
        action: "pause_landing_queue",
        state: state,
        payload: {}
      )

      expect(action).to be_valid
    end
  end

  it "validates job-control payloads include a job_id" do
    %w[cancel_job retry_job rebase_job reopen_epic_and_attach_job].each do |action_name|
      action = chat_session.pending_actions.build(action: action_name, payload: {})

      expect(action).not_to be_valid
      expect(action.errors[:payload]).to include("job_id is required")
    end
  end

  it "confirms a cancel_job action by closing the Job and cancelling active Runs" do
    job = Factories.job(repository: repository)
    run = job.current_run
    action = chat_session.pending_actions.create!(
      action: "cancel_job",
      payload: { "job_id" => job.id }
    )

    expect(action.confirm!).to be true

    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("cancelled")
    expect(run.reload).to be_cancelled
  end

  it "confirms a retry_job action by starting a retry Workflow" do
    job = direct_job
    Workflows::Initial.instantiate(job: job).update!(state: "succeeded")
    action = chat_session.pending_actions.create!(
      action: "retry_job",
      payload: { "job_id" => job.id }
    )

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(workflow.first_step.runs.count).to eq(1)
  end

  it "confirms a rebase_job action by starting a rebase Workflow" do
    job = direct_job(pr_number: 17)
    action = chat_session.pending_actions.create!(
      action: "rebase_job",
      payload: { "job_id" => job.id }
    )

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    workflow = job.workflows.where(trigger_kind: "rebase").last
    expect(workflow.first_step.runs.count).to eq(1)
  end

  it "confirms a reopen_epic_and_attach_job action" do
    epic = Factories.epic(user: user, repository: repository, state: "done", done_at: 60.days.ago)
    job = direct_job
    action = chat_session.pending_actions.create!(
      action: "reopen_epic_and_attach_job",
      payload: { "epic_id" => epic.id, "job_id" => job.id }
    )

    expect(action.confirm!).to be true

    expect(action.reload).to be_confirmed
    expect(epic.reload).to be_in_progress
    expect(job.reload.epic).to eq(epic)
  end

  it "does not confirm a stale rejected action" do
    job = direct_job
    action = chat_session.pending_actions.create!(
      action: "cancel_job",
      payload: { "job_id" => job.id }
    )
    action.reject!

    expect(action.confirm!).to be false
    expect(job.reload).to be_open
  end

  it "broadcasts pending_action_updated after confirmation" do
    allow(AppEvents).to receive(:broadcast)
    action = chat_session.pending_actions.create!(
      action: "pause_landing_queue",
      payload: {}
    )

    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "pending_action_updated" ],
      payload: {
        action: "pending_action_updated",
        pending_action_id: action.id,
        chat_message_id: nil,
        state: "confirmed"
      }
    )

    action.confirm!
  end

  def pending_action(**payload)
    described_class.create!(
      user: user,
      repository: repository,
      chat_session: chat_session,
      action_type: "schedule_recurring",
      payload: {
        "cron_expression" => "0 9 * * *",
        "label" => "Daily review",
        "prompt" => "Review the project."
      }.merge(payload)
    )
  end

  it "confirms a schedule_recurring action into a ScheduledTask" do
    action = pending_action

    expect {
      action.confirm!(user: user)
    }.to change { ScheduledTask.count }.by(1)

    task = ScheduledTask.last
    expect(task).to have_attributes(
      user: user,
      repository: repository,
      kind: "cron",
      name: "Daily review",
      prompt: "Review the project.",
      cron_expression: "0 9 * * *"
    )
    expect(action.reload).to be_confirmed
    expect(action.result).to eq(task)
  end

  it "fires a confirmed schedule_recurring action through cron Job semantics" do
    action = pending_action
    action.confirm!(user: user)
    task = action.result

    result = ScheduledTaskFire.new(task).call

    expect(result).to be_fired
    expect(result.job).to have_attributes(
      kind: "cron",
      scheduled_task: task,
      issue_number: nil
    )
    expect(result.job.runs.first.prompt).to include("scheduled maintenance task")
  end

  it "does not create the ScheduledTask before confirmation" do
    expect {
      pending_action
    }.not_to change { ScheduledTask.count }
  end

  it "confirms admin kill process by requesting a process kill" do
    admin = Factories.user(admin: true)
    admin_repository = Factories.repository(user: admin)
    admin_session = ChatSession.create!(user: admin, repository: admin_repository)
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "codex exec",
      hostname: "worker-a",
      pid: 123,
      started_at: 1.minute.ago
    )
    action = admin_session.pending_actions.create!(
      action: "admin_kill_process",
      payload: { "process_id" => process.id },
      requested_by: "agent"
    )

    expect(action.confirm!).to be true
    expect(process.reload.kill_requested_at).to be_present
    expect(process.kill_requested_by_user).to eq(admin)
  end

  it "confirms admin pause and unpause flags" do
    admin = Factories.user(admin: true)
    admin_repository = Factories.repository(user: admin)
    admin_session = ChatSession.create!(user: admin, repository: admin_repository)

    pause_polling = admin_session.pending_actions.create!(action: "admin_pause_polling", payload: {}, requested_by: "agent")
    unpause_polling = admin_session.pending_actions.create!(action: "admin_unpause_polling", payload: {}, requested_by: "agent")
    pause_runs = admin_session.pending_actions.create!(action: "admin_pause_runs", payload: {}, requested_by: "agent")
    unpause_runs = admin_session.pending_actions.create!(action: "admin_unpause_runs", payload: {}, requested_by: "agent")

    pause_polling.confirm!
    expect(AppSetting.current.reload.polling_paused).to be true
    unpause_polling.confirm!
    expect(AppSetting.current.reload.polling_paused).to be false
    pause_runs.confirm!
    expect(AppSetting.current.reload.runs_paused).to be true
    unpause_runs.confirm!
    expect(AppSetting.current.reload.runs_paused).to be false
  end

  it "confirms admin cache clear, reaper, installation refresh, and user scheduling actions" do
    admin = Factories.user(admin: true)
    admin_repository = Factories.repository(user: admin)
    admin_session = ChatSession.create!(user: admin, repository: admin_repository)
    target = Factories.user(scheduling_paused: false)

    allow(Rails.cache).to receive(:delete_matched).and_return(3)
    expect(ReapStaleRunsJob).to receive(:perform_later)
    admin_session.pending_actions.create!(action: "admin_reap_stale_runs", payload: {}, requested_by: "agent").confirm!

    admin_session.pending_actions.create!(action: "admin_clear_github_cache", payload: {}, requested_by: "agent").confirm!
    expect(Rails.cache).to have_received(:delete_matched).with("github_etag/*")

    admin_session.pending_actions.create!(
      action: "admin_pause_user_scheduling",
      payload: { "user_id" => target.id },
      requested_by: "agent"
    ).confirm!
    expect(target.reload.scheduling_paused).to be true

    admin_session.pending_actions.create!(
      action: "admin_unpause_user_scheduling",
      payload: { "user_id" => target.id },
      requested_by: "agent"
    ).confirm!
    expect(target.reload.scheduling_paused).to be false

    expect {
      admin_session.pending_actions.create!(action: "admin_refresh_installations", payload: {}, requested_by: "agent").confirm!
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)
  end

  it "confirms admin retry step and cleanup workspace actions" do
    admin = Factories.user(admin: true)
    admin_repository = Factories.repository(user: admin)
    admin_session = ChatSession.create!(user: admin, repository: admin_repository)
    job = Factories.job(user: admin, repository: admin_repository)
    workflow = job.initial_run.step.workflow
    step = workflow.steps.first

    workflow.update_columns(state: "failed", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)

    retry_action = admin_session.pending_actions.create!(
      action: "admin_retry_step",
      payload: { "workflow_id" => workflow.id, "step_slug" => step.kind },
      requested_by: "agent"
    )

    expect {
      retry_action.confirm!
    }.to change { step.runs.count }.by(1)
    expect(workflow.reload).to be_running
    expect(step.reload).to be_queued
    expect(retry_action.reload.result).to be_a(Run)

    allow_any_instance_of(Workflow).to receive(:cleanup_workspace!).and_return(true)
    cleanup_action = admin_session.pending_actions.create!(
      action: "admin_cleanup_workspace",
      payload: { "workflow_id" => workflow.id },
      requested_by: "agent"
    )

    expect(cleanup_action.confirm!).to be true
  end

  it "rejects mismatched repository and chat session" do
    other_repo = Factories.repository(user: user)
    action = described_class.new(
      user: user,
      repository: other_repo,
      chat_session: chat_session,
      action_type: "schedule_recurring",
      payload: { "cron_expression" => "0 9 * * *", "label" => "x", "prompt" => "y" }
    )

    expect(action).not_to be_valid
    expect(action.errors[:repository]).to be_present
  end

  describe "PendingActions registry" do
    it "raises UnknownAction for an unrecognized action key" do
      expect {
        PendingActions.for("totally_unknown_action")
      }.to raise_error(PendingActions::UnknownAction, /unknown pending action/)
    end

    it "includes expected action keys in the registry" do
      %w[cancel_job retry_job rebase_job schedule_recurring admin_kill_process pause_landing_queue].each do |key|
        expect(PendingActions::REGISTRY).to have_key(key), "expected registry to include '#{key}'"
      end
    end

    it "covers every ACTIONS entry and every ACTION_TYPES entry" do
      # Force auto-load of handlers that are only referenced by string key
      # in ChatPendingAction::ACTIONS, so their action_key registrations run.
      PendingActions::CompleteImplementStep
      all_keys = ChatPendingAction::ACTIONS + ChatPendingAction::ACTION_TYPES
      all_keys.each do |key|
        expect(PendingActions::REGISTRY).to have_key(key), "registry missing '#{key}'"
      end
    end
  end

  describe "outcome notification callback" do
    it "creates a system message and enqueues ChatTurnJob when confirmed" do
      allow(AppEvents).to receive(:broadcast)
      action = chat_session.pending_actions.create!(action: "pause_landing_queue", payload: {})

      expect {
        action.confirm!
      }.to change { chat_session.messages.where(role: "system").count }.by(1)
        .and have_enqueued_job(ChatTurnJob)

      message = chat_session.messages.where(role: "system").last
      expect(message.content["source"]).to eq(ChatPendingActionOutcomeNotification::SOURCE)
      expect(message.content["outcome"]).to eq("confirmed")
      expect(message.content["text"]).to include("confirmed").and include("pause_landing_queue")
    end

    it "creates a system message and enqueues ChatTurnJob when rejected" do
      allow(AppEvents).to receive(:broadcast)
      action = chat_session.pending_actions.create!(action: "pause_landing_queue", payload: {})

      expect {
        action.reject!
      }.to change { chat_session.messages.where(role: "system").count }.by(1)
        .and have_enqueued_job(ChatTurnJob)

      message = chat_session.messages.where(role: "system").last
      expect(message.content["outcome"]).to eq("rejected")
      expect(message.content["text"]).to include("rejected")
    end

    it "creates a system message and enqueues ChatTurnJob when cancelled" do
      allow(AppEvents).to receive(:broadcast)
      action = chat_session.pending_actions.create!(action: "pause_landing_queue", payload: {})

      expect {
        action.cancel!
      }.to change { chat_session.messages.where(role: "system").count }.by(1)
        .and have_enqueued_job(ChatTurnJob)

      message = chat_session.messages.where(role: "system").last
      expect(message.content["outcome"]).to eq("cancelled")
      expect(message.content["text"]).to include("dismissed")
    end

    it "does not enqueue ChatTurnJob when state does not change" do
      allow(AppEvents).to receive(:broadcast)
      action = chat_session.pending_actions.create!(action: "pause_landing_queue", payload: {})
      action.confirm!

      expect {
        action.update!(updated_at: Time.current)
      }.not_to have_enqueued_job(ChatTurnJob)
    end

    it "includes the job_id detail for job-scoped actions" do
      allow(AppEvents).to receive(:broadcast)
      job = direct_job
      action = chat_session.pending_actions.create!(action: "cancel_job", payload: { "job_id" => job.id })

      action.reject!

      message = chat_session.messages.where(role: "system").last
      expect(message.content["text"]).to include("job_id: #{job.id}")
    end
  end
end
