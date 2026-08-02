require "rails_helper"

RSpec.describe ChatEventEvaluator do
  Result = Struct.new(:final_text, keyword_init: true)

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, chat_provider: "claude") }
  let(:event) do
    ChatScopedEvent.create!(
      chat_session: chat_session,
      repository: repository,
      source_kind: "job_failed",
      payload: { "summary" => "Job failed", "severity" => "warning" }
    )
  end

  def message(role, text, **attrs)
    chat_session.messages.create!(
      role: role,
      content: { "text" => text },
      **attrs
    )
  end

  it "clones the full persisted transcript when caps are not needed" do
    message("user", "first request")
    message("assistant", "first answer")
    message("user", "latest request")

    calls = []
    runner = lambda do |**kwargs|
      calls << kwargs
      Result.new(final_text: JSON.generate(decision: "no_op", reason: "covered", urgency: 0, confidence: 0.9))
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call

    expect(result.dig("context_clone", "capped")).to eq(false)
    expect(result.dig("context_clone", "cloned_message_count")).to eq(3)
    expect(calls.first.fetch(:transcript_jsonl)).to include("first request", "first answer", "latest request")
  end

  it "falls back to the latest capped message window and trims oversized content" do
    stub_const("#{described_class}::MAX_MESSAGES", 3)
    stub_const("#{described_class}::MAX_TRANSCRIPT_BYTES", 500)

    message("user", "old request")
    message("assistant", "middle answer")
    chat_session.messages.create!(
      role: "tool_result",
      content: { "result" => "x" * 5_000, "is_error" => false },
      tool_use_id: "toolu_1"
    )
    message("user", "new request")

    calls = []
    runner = lambda do |**kwargs|
      calls << kwargs
      Result.new(final_text: JSON.generate(decision: "respond", reason: "needs visibility", urgency: 0.6, confidence: 0.8, handoff_prompt: "Summarize it."))
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call
    transcript = calls.first.fetch(:transcript_jsonl)

    expect(result.dig("context_clone", "message_cap_applied")).to eq(true)
    expect(result.dig("context_clone", "byte_cap_applied")).to eq(true)
    expect(result.dig("context_clone", "cloned_message_count")).to eq(3)
    expect(transcript).not_to include("old request")
    expect(transcript).to include("new request", "disposable evaluator transcript byte cap")
  end

  it "persists a no-op evaluator result without mutating the live provider session" do
    live_session = chat_session.create_claude_session!(
      provider: "claude",
      session_id: "live-session",
      transcript_jsonl: "{\"type\":\"system\"}\n"
    )
    message("user", "hello")

    runner = lambda do |**_kwargs|
      Result.new(final_text: JSON.generate(decision: "no_op", reason: "duplicate event", urgency: 0.1, confidence: 1.0))
    end

    described_class.new(event: event, chat_session: chat_session, runner: runner).call

    event.reload
    expect(event.evaluator_state).to eq("completed")
    expect(event.evaluator_result).to include("decision" => "no_op", "reason" => "duplicate event")
    expect(event.evaluated_at).to be_present
    expect(chat_session.reload.claude_session).to eq(live_session)
    expect(chat_session.claude_session.session_id).to eq("live-session")
    expect(ClaudeSession.where(resumable: chat_session).count).to eq(1)
  end
end
