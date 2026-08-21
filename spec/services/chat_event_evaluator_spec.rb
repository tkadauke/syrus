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

  it "detects capped context without counting the whole chat" do
    stub_const("#{described_class}::MAX_MESSAGES", 3)
    4.times { |index| message(index.even? ? "user" : "assistant", "message #{index}") }
    runner = lambda do |**_kwargs|
      Result.new(final_text: JSON.generate(decision: "no_op", reason: "covered", urgency: 0, confidence: 0.9))
    end

    queries = capture_sql { described_class.new(event: event, chat_session: chat_session, runner: runner).call }

    expect(queries.grep(/COUNT\\(\\*\\).*chat_messages/i)).to be_empty
    expect(event.reload.evaluator_result.dig("context_clone", "message_cap_applied")).to eq(true)
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless payload[:name] == "SCHEMA" || sql.include?("sqlite_master")
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "persists a no-op evaluator result without mutating the live provider session" do
    live_session = chat_session.create_provider_session!(
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
    expect(chat_session.reload.provider_session).to eq(live_session)
    expect(chat_session.provider_session.session_id).to eq("live-session")
    expect(ProviderSession.where(resumable: chat_session).count).to eq(1)
  end

  it "accepts a structured MCP tool decision even when final text is malformed" do
    runner = lambda do |**kwargs|
      kwargs.fetch(:event).update!(
        evaluator_result: {
          "decision" => "act",
          "reason" => "tool submitted the decision",
          "urgency" => 0.8,
          "confidence" => 0.9,
          "handoff_prompt" => "Inspect the failed job.",
          "submitted_via" => "mcp_tool"
        }
      )
      Result.new(final_text: "{not json")
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call

    expect(result).to include(
      "decision" => "act",
      "reason" => "tool submitted the decision",
      "submitted_via" => "mcp_tool"
    )
    expect(result.dig("context_clone", "source_message_count")).to eq(0)
    expect(event.reload).to be_evaluator_completed
  end

  it "retries malformed JSON once with a repair prompt before failing" do
    calls = []
    runner = lambda do |**kwargs|
      calls << kwargs.fetch(:prompt)
      if calls.one?
        Result.new(final_text: '{ "decision" "respond" }')
      else
        Result.new(final_text: JSON.generate(decision: "respond", reason: "fixed json", urgency: 0.4, confidence: 0.7))
      end
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call

    expect(calls.size).to eq(2)
    expect(calls.second).to include("previous scoped event evaluator response was not usable")
    expect(result).to include("decision" => "respond", "reason" => "fixed json")
  end

  it "treats malformed low-severity informational events as no-op after the repair retry fails" do
    event.update!(
      source_kind: "pull_request_merged",
      payload: { "kind" => "pr_merged", "severity" => "info", "summary" => "PR merged" }
    )
    runner = lambda do |**_kwargs|
      Result.new(final_text: '{ "decision" "respond" }')
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call

    expect(result).to include("decision" => "no_op", "submitted_via" => "low_severity_parse_fallback")
    expect(event.reload).to be_evaluator_completed
  end

  it "falls back to a low-confidence response for critical evaluator parse failures" do
    event.update!(payload: { "summary" => "Job failed", "severity" => "critical" })
    runner = lambda do |**_kwargs|
      Result.new(final_text: '{ "decision" "respond" }')
    end

    result = described_class.new(event: event, chat_session: chat_session, runner: runner).call

    expect(result).to include(
      "decision" => "respond",
      "confidence" => 0.0,
      "submitted_via" => "parse_failure_fallback"
    )
    expect(result.fetch("handoff_prompt")).to include("Evaluator parse error", "Job failed")
    expect(event.reload).to be_evaluator_completed
  end
end
