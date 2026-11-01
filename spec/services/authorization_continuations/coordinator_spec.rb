require "rails_helper"

RSpec.describe AuthorizationContinuations::Coordinator, :ci_only do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }

  before { clear_enqueued_jobs }

  def request_for(origin, checkpoint: { provider: "codex", cursor: "checkpoint-1" })
    request = ChatPendingAction.create!(
      request_kind: "authorization_request",
      user:,
      repository:,
      origin:,
      subject: user,
      runtime_role: origin.is_a?(Run) ? "implementer" : "interactive_chat",
      deduplication_key: "authorization-continuation-#{origin.class.name}-#{origin.id}-#{SecureRandom.hex(4)}"
    )
    request.checkpoint_authorization!(payload: checkpoint)
    request
  end

  it "starts one fresh chat continuation containing the exact result and prior checkpoint" do
    chat = ChatSession.create!(user:, repository:)
    request = request_for(chat)
    clear_enqueued_jobs
    exact_result = { "content" => [ { "type" => "text", "text" => "rows: 2" } ], "is_error" => false }

    first = described_class.call(request:, outcome: :approved, tool_result: exact_result)
    second = described_class.call(request: request.reload, outcome: :approved, tool_result: exact_result)

    expect(first.status).to eq(:delivered)
    expect(second.status).to eq(:already_claimed)
    expect(request.reload).to have_attributes(checkpoint_state: "resumed", resume_attempts: 1)
    messages = chat.reload.messages.where(role: "system")
    expect(messages.size).to eq(1)
    expect(messages.first.content).to include(
      "authorization_continuation" => true,
      "source" => "authorization_continuation"
    )
    prompt = messages.first.content.fetch("internal_prompt")
    continuation = JSON.parse(prompt[prompt.index("{")..])
    expect(continuation).to include(
      "tool_result" => exact_result,
      "checkpoint" => hash_including("cursor" => "checkpoint-1")
    )
    expect(enqueued_jobs.count { |job| job[:job] == ChatTurnJob }).to eq(1)
  end

  it "delivers a structured denial without a tool result" do
    chat = ChatSession.create!(user:, repository:)
    request = request_for(chat)
    clear_enqueued_jobs

    result = described_class.call(request:, outcome: :denied, denial_reason: "Operator declined")

    expect(result.continuation).to include(
      "outcome" => "denied",
      "denial" => { "code" => "authorization_denied", "reason" => "Operator declined" },
      "checkpoint" => hash_including("cursor" => "checkpoint-1")
    )
    expect(result.continuation).not_to have_key("tool_result")
  end

  it "retries after delivery failure without losing or duplicating the checkpoint claim" do
    chat = ChatSession.create!(user:, repository:)
    request = request_for(chat)
    clear_enqueued_jobs
    adapter = instance_double(AuthorizationContinuations::ChatOrigin, resumable?: true, complete_on_delivery?: true)
    allow(AuthorizationContinuations::Origin).to receive(:for).and_return(adapter)
    allow(adapter).to receive(:deliver!).and_raise("queue unavailable")

    expect { described_class.call(request:, outcome: :denied) }.to raise_error("queue unavailable")
    expect(request.reload).to have_attributes(checkpoint_state: "resume_failed", resume_attempts: 1)

    allow(adapter).to receive(:deliver!)
    allow(adapter).to receive(:dispatch!)
    expect(described_class.call(request: request.reload, outcome: :denied).status).to eq(:delivered)
    expect(request.reload).to have_attributes(checkpoint_state: "resumed", resume_attempts: 2)
  end

  it "marks a stale origin non-resumable and does not dispatch" do
    chat = ChatSession.create!(user:, repository:, stop_requested_at: Time.current)
    request = request_for(chat)
    clear_enqueued_jobs

    expect(described_class.call(request:, outcome: :denied).status).to eq(:non_resumable)
    expect(request.reload).to have_attributes(
      checkpoint_state: "non_resumable",
      last_resume_error: "origin_no_longer_resumable"
    )
    expect(enqueued_jobs).to be_empty
  end

  it "prepares a running workflow Run for a fresh provider turn" do
    job = Factories.job(user:, repository:)
    workflow = job.workflows.first
    run = workflow.runs.first
    workflow.update!(state: "running")
    run.step.update!(state: "running")
    run.update!(state: "running", started_at: Time.current, parent_session_id: "old-session")
    request = request_for(run)
    clear_enqueued_jobs

    described_class.call(request:, outcome: :approved, tool_result: { "value" => 7 })

    expect(run.reload.parent_session_id).to eq(Steps::Base::DISABLE_AGENT_RESUME)
    expect(run.prompt).to include('"value": 7', '"cursor": "checkpoint-1"')
    expect(request.reload.checkpoint_state).to eq("resuming")
    expect(described_class.call(request: request.reload, outcome: :approved, tool_result: { "value" => 7 }).status)
      .to eq(:already_claimed)
    expect(enqueued_jobs.count { |queued| queued[:job] == RunJob }).to eq(1)
  end

  it "lets RunJob claim the prepared continuation only once" do
    job = Factories.job(user:, repository:)
    workflow = job.workflows.first
    run = workflow.runs.first
    workflow.update!(state: "running")
    run.step.update!(state: "running")
    run.update!(state: "running", started_at: Time.current)
    request = request_for(run)
    described_class.call(request:, outcome: :denied)

    runner = RunJob.new
    runner.instance_variable_set(:@run, run.reload)

    expect(runner.send(:authorization_continuation?)).to be(true)
    expect(request.reload.checkpoint_state).to eq("resumed")
    expect(runner.send(:authorization_continuation?)).to be(false)
  end
end
