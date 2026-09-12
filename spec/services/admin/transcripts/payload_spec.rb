require "rails_helper"

RSpec.describe Admin::Transcripts::Payload do
  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  it "resolves a chat ProviderSession through its Agent without Run breadcrumbs or JobLog fallback" do
    user = Factories.user
    chat = ChatSession.create!(user: user, title: "Planning", chat_provider: "codex")
    agent = Agent.find_or_create_for!(chat)
    chat.create_provider_session!(
      provider: "codex",
      session_id: "chat-session-1",
      transcript_jsonl: jsonl(
        { "type" => "system", "subtype" => "init", "model" => "gpt-5-codex", "session_id" => "chat-session-1" },
        { "type" => "result", "subtype" => "success", "num_turns" => 1, "total_cost_usd" => 0.02, "is_error" => false }
      )
    )

    payload = described_class.new(params: {}).show_for_agent(agent.id)

    expect(payload).to include(
      agent_id: agent.id,
      resumable_type: "ChatSession",
      resumable_id: chat.id,
      run_id: nil,
      job_id: nil,
      step_kind: nil,
      workflow_trigger_kind: nil,
      session_id: "chat-session-1"
    )
    expect(payload.fetch(:summary)).to include(
      model: "gpt-5-codex",
      total_turns: 1,
      total_cost_usd: 0.02
    )
    expect(payload.fetch(:events).map { |event| event.fetch(:kind) }).to eq(%w[system_init result])
  end

  it "keeps JobLog fallback scoped to Run transcripts" do
    job = Factories.job
    run = job.initial_run
    Agent.find_or_create_for!(run)
    JobLog.append!(run: run, chunk: "fallback transcript row", kind: "system")

    payload = described_class.new(params: {}).show_for_resumable(type: "Run", id: run.id)

    expect(payload).to include(
      resumable_type: "Run",
      resumable_id: run.id,
      run_id: run.id,
      job_id: job.id
    )
    expect(payload.fetch(:events).map { |event| event.fetch(:kind) }).to eq([ "job_log" ])
  end
end
