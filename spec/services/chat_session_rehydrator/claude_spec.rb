require "rails_helper"

RSpec.describe ChatSessionRehydrator::Claude do
  include ActiveJob::TestHelper

  let(:user)    { Factories.user }
  let(:session) { ChatSession.create!(user: user) }

  before { allow(AppEvents).to receive(:broadcast) }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Parses rehydrated JSONL back into ClaudeTranscript events for comparison.
  def events_from(jsonl)
    ClaudeTranscript.new(jsonl).events.to_a
  end

  def create_message!(role:, content:, tool_name: nil, tool_use_id: nil)
    session.messages.create!(role: role, content: content, tool_name: tool_name, tool_use_id: tool_use_id)
  end

  # ---------------------------------------------------------------------------
  # Unit: empty session
  # ---------------------------------------------------------------------------

  it "produces a single system-init line when the session has no messages and session_id is given" do
    jsonl = described_class.new(session, session_id: "s1").call

    lines = jsonl.lines.map { |l| JSON.parse(l) }
    expect(lines.size).to eq(1)
    expect(lines.first).to include("type" => "system", "subtype" => "init", "session_id" => "s1")
  end

  it "produces an empty string (no lines) when there are no messages and no session_id" do
    session.messages.none  # ensure empty
    jsonl = described_class.new(session).call
    expect(jsonl).to eq("\n")
  end

  # ---------------------------------------------------------------------------
  # Unit: user message
  # ---------------------------------------------------------------------------

  it "emits a user JSONL event for a user ChatMessage" do
    create_message!(role: "user", content: { "text" => "Hello there." })

    jsonl   = described_class.new(session).call
    events  = events_from(jsonl)
    prompts = events.select { |e| e.kind == :user_prompt }

    expect(prompts.size).to eq(1)
    expect(prompts.first.data[:text]).to eq("Hello there.")
  end

  # ---------------------------------------------------------------------------
  # Unit: assistant message (text only, no tools)
  # ---------------------------------------------------------------------------

  it "emits an assistant JSONL event for an assistant ChatMessage (canonical blocks)" do
    create_message!(role: "assistant", content: [
      { "type" => "text", "text" => "Sure, I can help." }
    ])

    jsonl  = described_class.new(session).call
    events = events_from(jsonl)
    texts  = events.select { |e| e.kind == :assistant_text }

    expect(texts.size).to eq(1)
    expect(texts.first.data[:text]).to eq("Sure, I can help.")
  end

  it "normalizes a legacy flat-format assistant message to a text block" do
    create_message!(role: "assistant", content: { "text" => "Legacy response." })

    jsonl  = described_class.new(session).call
    events = events_from(jsonl)
    texts  = events.select { |e| e.kind == :assistant_text }

    expect(texts.size).to eq(1)
    expect(texts.first.data[:text]).to eq("Legacy response.")
  end

  # ---------------------------------------------------------------------------
  # Unit: thinking blocks are preserved
  # ---------------------------------------------------------------------------

  it "includes thinking blocks in the assistant JSONL event" do
    create_message!(role: "assistant", content: [
      { "type" => "thinking", "thinking" => "inner thoughts", "signature" => "sig123" },
      { "type" => "text", "text" => "Ok." }
    ])

    jsonl = described_class.new(session).call
    lines = jsonl.lines.map { |l| JSON.parse(l) }
    asst  = lines.find { |l| l["type"] == "assistant" }

    expect(asst).not_to be_nil
    content = asst.dig("message", "content")
    expect(content).to include(a_hash_including("type" => "thinking", "thinking" => "inner thoughts", "signature" => "sig123"))
    expect(content).to include(a_hash_including("type" => "text", "text" => "Ok."))
  end

  # ---------------------------------------------------------------------------
  # Unit: tool use and result
  # ---------------------------------------------------------------------------

  it "merges assistant + tool_use rows into one JSONL assistant event" do
    create_message!(role: "assistant", content: [{ "type" => "text", "text" => "Reading…" }])
    create_message!(role: "tool_use", tool_name: "Read", tool_use_id: "t1",
                    content: { "type" => "tool_use", "id" => "t1", "name" => "Read", "input" => { "file_path" => "/x" } })

    jsonl = described_class.new(session).call
    lines = jsonl.lines.map { |l| JSON.parse(l) }
    asst  = lines.select { |l| l["type"] == "assistant" }

    expect(asst.size).to eq(1)
    content = asst.first.dig("message", "content")
    expect(content.size).to eq(2)
    expect(content).to include(a_hash_including("type" => "text", "text" => "Reading…"))
    expect(content).to include(a_hash_including("type" => "tool_use", "id" => "t1", "name" => "Read"))
  end

  it "emits a user JSONL event with array content for tool_result rows" do
    create_message!(role: "assistant", content: [{ "type" => "text", "text" => "Let me look." }])
    create_message!(role: "tool_use", tool_name: "Read", tool_use_id: "t1",
                    content: { "type" => "tool_use", "id" => "t1", "name" => "Read", "input" => { "file_path" => "/x" } })
    create_message!(role: "tool_result", tool_name: "Read", tool_use_id: "t1",
                    content: { "type" => "tool_result", "tool_use_id" => "t1", "content" => "file body", "is_error" => false })

    jsonl   = described_class.new(session).call
    events  = events_from(jsonl)
    results = events.select { |e| e.kind == :tool_result }

    expect(results.size).to eq(1)
    expect(results.first.data[:tool_use_id]).to eq("t1")
    expect(results.first.data[:content]).to eq("file body")
    expect(results.first.data[:error]).to be false
  end

  it "groups consecutive tool_result rows into one user JSONL array event" do
    create_message!(role: "assistant", content: [
      { "type" => "text", "text" => "Two tools:" },
      { "type" => "tool_use", "id" => "t1", "name" => "Read",  "input" => {} },
      { "type" => "tool_use", "id" => "t2", "name" => "Write", "input" => {} }
    ])
    create_message!(role: "tool_use", tool_name: "Read",  tool_use_id: "t1",
                    content: { "type" => "tool_use", "id" => "t1", "name" => "Read",  "input" => {} })
    create_message!(role: "tool_use", tool_name: "Write", tool_use_id: "t2",
                    content: { "type" => "tool_use", "id" => "t2", "name" => "Write", "input" => {} })
    create_message!(role: "tool_result", tool_name: "Read",  tool_use_id: "t1",
                    content: { "type" => "tool_result", "tool_use_id" => "t1", "content" => "r1", "is_error" => false })
    create_message!(role: "tool_result", tool_name: "Write", tool_use_id: "t2",
                    content: { "type" => "tool_result", "tool_use_id" => "t2", "content" => "r2", "is_error" => false })

    jsonl        = described_class.new(session).call
    lines        = jsonl.lines.map { |l| JSON.parse(l) }
    user_events  = lines.select { |l| l["type"] == "user" }
    # All tool_results land in exactly one user event with array content.
    tool_result_user = user_events.find { |e| e.dig("message", "content").is_a?(Array) }

    expect(tool_result_user).not_to be_nil
    expect(tool_result_user.dig("message", "content").size).to eq(2)
  end

  it "normalizes legacy tool_use rows when canonical_content_format? is false" do
    create_message!(role: "tool_use", tool_name: "Grep", tool_use_id: "t1",
                    content: { "input" => { "pattern" => "foo" } })

    jsonl = described_class.new(session).call
    lines = jsonl.lines.map { |l| JSON.parse(l) }
    asst  = lines.find { |l| l["type"] == "assistant" }

    expect(asst).not_to be_nil
    content = asst.dig("message", "content")
    expect(content).to include(a_hash_including("type" => "tool_use", "id" => "t1", "name" => "Grep", "input" => { "pattern" => "foo" }))
  end

  it "normalizes legacy tool_result rows when canonical_content_format? is false" do
    create_message!(role: "tool_result", tool_name: "Grep", tool_use_id: "t1",
                    content: { "result" => "grep output", "is_error" => false })

    jsonl   = described_class.new(session).call
    events  = events_from(jsonl)
    results = events.select { |e| e.kind == :tool_result }

    expect(results.size).to eq(1)
    expect(results.first.data[:content]).to eq("grep output")
    expect(results.first.data[:error]).to be false
  end

  it "skips system ChatMessages (Syrus status rows)" do
    create_message!(role: "user",   content: { "text" => "Hello." })
    create_message!(role: "system", content: { "text" => "[mcp connected]" })
    create_message!(role: "assistant", content: [{ "type" => "text", "text" => "Hi." }])

    jsonl  = described_class.new(session).call
    events = events_from(jsonl)

    expect(events.none? { |e| e.kind == :other }).to be true
    expect(events.map(&:kind)).to contain_exactly(:user_prompt, :assistant_text)
  end

  # ---------------------------------------------------------------------------
  # Round-trip spec
  # ---------------------------------------------------------------------------
  # Given a known-good Claude Code session JSONL, ingest it into ChatMessage
  # rows (as ChatTurnJob would), run the rehydrator, parse the output with
  # ClaudeTranscript, and verify structural equivalence.
  # ---------------------------------------------------------------------------

  describe "round-trip: Claude Code JSONL → ChatMessage rows → rehydrated JSONL" do
    # Fixture: a realistic two-tool-call session with a thinking block.
    let(:fixture_jsonl) do
      [
        { "type" => "system", "subtype" => "init",
          "session_id" => "sess-rt-1", "model" => "claude-sonnet-4-6",
          "cwd" => "/tmp/chat-ws",
          "tools" => [ "Read", "Bash", "mcp__syrus-mcp-sidecar__submit_summary" ],
          "timestamp" => "2026-07-01T00:00:00Z" },
        { "type" => "user",
          "message" => { "role" => "user", "content" => "What is in /etc/hosts?" },
          "timestamp" => "2026-07-01T00:00:01Z" },
        { "type" => "assistant",
          "message" => { "content" => [
            { "type" => "thinking", "thinking" => "I should read the file.", "signature" => "sig-a" },
            { "type" => "text", "text" => "Let me check." },
            { "type" => "tool_use", "id" => "tu1", "name" => "Read",
              "input" => { "file_path" => "/etc/hosts" } }
          ] },
          "timestamp" => "2026-07-01T00:00:02Z" },
        { "type" => "user",
          "message" => { "role" => "user", "content" => [
            { "type" => "tool_result", "tool_use_id" => "tu1",
              "content" => "127.0.0.1 localhost", "is_error" => false }
          ] },
          "timestamp" => "2026-07-01T00:00:03Z" },
        { "type" => "assistant",
          "message" => { "content" => [
            { "type" => "text", "text" => "The file contains localhost entries." },
            { "type" => "tool_use", "id" => "tu2", "name" => "Bash",
              "input" => { "command" => "echo done" } }
          ] },
          "timestamp" => "2026-07-01T00:00:04Z" },
        { "type" => "user",
          "message" => { "role" => "user", "content" => [
            { "type" => "tool_result", "tool_use_id" => "tu2",
              "content" => "done", "is_error" => false }
          ] },
          "timestamp" => "2026-07-01T00:00:05Z" },
        { "type" => "assistant",
          "message" => { "content" => [
            { "type" => "text", "text" => "All done." }
          ] },
          "timestamp" => "2026-07-01T00:00:06Z" },
        { "type" => "result", "subtype" => "success",
          "num_turns" => 2, "total_cost_usd" => 0.001,
          "timestamp" => "2026-07-01T00:00:07Z" }
      ].map(&:to_json).join("\n") + "\n"
    end

    # Ingest fixture JSONL into ChatMessage rows, matching what ChatTurnJob creates.
    before do
      # Turn 1: user → assistant (thinking + text + tool_use) → tool_result
      create_message!(role: "user", content: { "text" => "What is in /etc/hosts?" })
      # ChatTurnJob flushes thinking+text before tool_call, producing one assistant row
      create_message!(role: "assistant", content: [
        { "type" => "thinking", "thinking" => "I should read the file.", "signature" => "sig-a" },
        { "type" => "text", "text" => "Let me check." }
      ])
      create_message!(role: "tool_use", tool_name: "Read", tool_use_id: "tu1",
                      content: { "type" => "tool_use", "id" => "tu1", "name" => "Read",
                                 "input" => { "file_path" => "/etc/hosts" } })
      create_message!(role: "tool_result", tool_name: "Read", tool_use_id: "tu1",
                      content: { "type" => "tool_result", "tool_use_id" => "tu1",
                                 "content" => "127.0.0.1 localhost", "is_error" => false })

      # Turn 2: assistant (text + tool_use) → tool_result → assistant (final text)
      create_message!(role: "assistant", content: [
        { "type" => "text", "text" => "The file contains localhost entries." }
      ])
      create_message!(role: "tool_use", tool_name: "Bash", tool_use_id: "tu2",
                      content: { "type" => "tool_use", "id" => "tu2", "name" => "Bash",
                                 "input" => { "command" => "echo done" } })
      create_message!(role: "tool_result", tool_name: "Bash", tool_use_id: "tu2",
                      content: { "type" => "tool_result", "tool_use_id" => "tu2",
                                 "content" => "done", "is_error" => false })
      create_message!(role: "assistant", content: [
        { "type" => "text", "text" => "All done." }
      ])
    end

    it "produces structurally equivalent events when compared to the original fixture" do
      fixture_events   = ClaudeTranscript.new(fixture_jsonl).events.reject { |e| e.kind == :other }.to_a
      rehydrated_jsonl = described_class.new(session, session_id: "sess-rt-1",
                                             cwd: "/tmp/chat-ws",
                                             model: "claude-sonnet-4-6",
                                             tools: [ "Read", "Bash", "mcp__syrus-mcp-sidecar__submit_summary" ]).call
      rehydrated_events = ClaudeTranscript.new(rehydrated_jsonl).events.reject { |e| e.kind == :result }.to_a

      # System init
      expect(rehydrated_events.first.kind).to eq(:system_init)
      expect(rehydrated_events.first.data[:session_id]).to eq("sess-rt-1")
      expect(rehydrated_events.first.data[:model]).to eq("claude-sonnet-4-6")

      # Extract just the conversation events (skip system_init from both)
      fixture_conv    = fixture_events.reject { |e| e.kind == :system_init || e.kind == :result }
      rehydrated_conv = rehydrated_events.reject { |e| e.kind == :system_init }

      expect(rehydrated_conv.map(&:kind)).to eq(fixture_conv.map(&:kind))

      # User prompt
      user_ev = rehydrated_conv.find { |e| e.kind == :user_prompt }
      expect(user_ev.data[:text]).to eq("What is in /etc/hosts?")

      # Assistant text events
      assistant_texts = rehydrated_conv.select { |e| e.kind == :assistant_text }.map { |e| e.data[:text] }
      expect(assistant_texts).to include("Let me check.", "The file contains localhost entries.", "All done.")

      # Tool use events
      tool_uses = rehydrated_conv.select { |e| e.kind == :tool_use }
      expect(tool_uses.map { |e| e.data[:name] }).to contain_exactly("Read", "Bash")

      # Tool result events
      tool_results = rehydrated_conv.select { |e| e.kind == :tool_result }
      expect(tool_results.map { |e| e.data[:tool_use_id] }).to contain_exactly("tu1", "tu2")
      expect(tool_results.all? { |e| !e.data[:error] }).to be true
    end

    it "preserves thinking blocks in the rehydrated assistant events" do
      rehydrated_jsonl = described_class.new(session, session_id: "sess-rt-1").call
      lines            = rehydrated_jsonl.lines.map { |l| JSON.parse(l) }
      first_asst       = lines.find { |l| l["type"] == "assistant" }

      expect(first_asst.dig("message", "content")).to include(
        a_hash_including("type" => "thinking", "thinking" => "I should read the file.", "signature" => "sig-a")
      )
    end

    it "merges thinking + text + tool_use into a single assistant JSONL event" do
      rehydrated_jsonl = described_class.new(session, session_id: "sess-rt-1").call
      lines            = rehydrated_jsonl.lines.map { |l| JSON.parse(l) }
      first_asst       = lines.find { |l| l["type"] == "assistant" }
      content          = first_asst.dig("message", "content")

      types = content.map { |b| b["type"] }
      expect(types).to eq(%w[thinking text tool_use])
    end
  end
end
