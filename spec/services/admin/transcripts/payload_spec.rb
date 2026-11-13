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
      run_id: nil,
      job_id: nil,
      step_kind: nil,
      workflow_trigger_kind: nil,
      session_id: "chat-session-1",
      finished: false
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
      run_id: run.id,
      job_id: job.id
    )
    expect(payload.fetch(:events).map { |event| event.fetch(:kind) }).to eq([ "job_log" ])
  end

  it "reports whether a Run is terminal so clients can stop polling" do
    job = Factories.job
    run = job.initial_run

    active_payload = described_class.new(params: {}).show(run.id)
    run.update!(state: "failed", finished_at: Time.current)
    finished_payload = described_class.new(params: {}).show(run.id)

    expect(active_payload.fetch(:finished)).to be(false)
    expect(finished_payload.fetch(:finished)).to be(true)
  end

  it "returns only events after the supplied cursor" do
    run = Factories.job.initial_run
    run.create_provider_session!(provider: "codex", session_id: "delta", transcript_jsonl: jsonl(
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "first" } ] } },
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "second" } ] } }
    ))

    payload = described_class.new(params: { after_event: "1" }).show(run.id)

    expect(payload.fetch(:events)).to contain_exactly(include(index: 1, data: include(text: "second")))
    expect(payload.dig(:pagination, :total_events)).to eq(2)
  end

  it "previews oversized event bodies and serves the full indexed event separately" do
    run = Factories.job.initial_run
    full_text = "x" * (described_class::MAX_INLINE_EVENT_BYTES + 1)
    run.create_provider_session!(provider: "codex", session_id: "large", transcript_jsonl: jsonl(
      { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => full_text } ] } }
    ))
    payload = described_class.new(params: {}).show(run.id)

    expect(payload.fetch(:events).first).to include(index: 0, body_truncated: true)
    expect(payload.dig(:events, 0, :data, :text).bytesize).to be < full_text.bytesize
    expect(described_class.new(params: {}).event(run.id, 0).dig(:data, :text)).to eq(full_text)
  end
end
