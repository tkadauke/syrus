require "rails_helper"

RSpec.describe PendingActions::Invocation do
  include ActiveJob::TestHelper

  NonChatInvocation = Struct.new(:payload, :reason, :user, :repository, keyword_init: true) do
    include PendingActions::Invocation

    def chat_session
      nil
    end
  end

  def non_chat_invocation(user:, repository:, payload: {}, reason: "operator repair")
    NonChatInvocation.new(
      payload: payload,
      reason: reason,
      user: user,
      repository: repository
    )
  end

  def build_workflow(job, workflow_state: "running", unit_state: workflow_state)
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "claude")
    workflow.update_columns(state: workflow_state)
    attach_work_unit(workflow, state: unit_state)
    workflow
  end

  def build_run(job, workflow, state: "queued")
    Run.create!(
      job: job,
      user: job.user,
      step: workflow.first_step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: state
    )
  end

  it "executes reenqueue work with a non-chat invocation and no ChatSession records" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    job = Factories.job_record(state: "running", repository: repository, user: admin, agent_provider: "claude")
    workflow = build_workflow(job)
    run = build_run(job, workflow, state: "queued")
    invocation = non_chat_invocation(
      user: admin,
      repository: repository,
      payload: { "job_id" => job.id, "run_id" => run.id },
      reason: "Run is queued but the queue claim disappeared."
    )

    expect(ChatSession.count).to eq(0)
    expect {
      expect(PendingActions::ReenqueueWork.new(invocation).execute).to eq(run)
    }.to have_enqueued_job(RunJob).with(run.id)
    expect(ChatSession.count).to eq(0)
    expect(JobLog.where(run: run).pluck(:chunk)).to include(a_string_matching(/re-enqueued work via #{Regexp.escape(run.slug)}/))
  end

  it "does not raise when a non-chat invocation receives progress updates" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    invocation = non_chat_invocation(user: admin, repository: repository)

    expect {
      PendingActions::PauseLandingQueue.new(invocation).send(:progress!, "Still working...")
    }.not_to raise_error
  end

  it "constructs every registered chat pending action with a non-chat invocation" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    invocation = non_chat_invocation(user: admin, repository: repository)

    expect(ChatPendingAction::ACTIONS.size).to eq(57)
    expect(ChatPendingAction::ACTIONS).to include("repair_queue_affinity")
    ChatPendingAction::ACTIONS.each do |action_key|
      command = PendingActions.for(action_key).new(invocation)

      expect(command.class.action_key).to eq(action_key)
    end
  end

  it "requires chat only for actions that explicitly declare the dependency" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    invocation = non_chat_invocation(
      user: admin,
      repository: repository,
      payload: { "tool_name" => "run_command", "arguments" => { "command" => "pwd" } }
    )

    expect(PendingActions::LocalToolCall).to be_requires_chat_session
    expect {
      PendingActions::LocalToolCall.new(invocation).execute
    }.to raise_error(ArgumentError, /requires a ChatSession/)
  end
end
