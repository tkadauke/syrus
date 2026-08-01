require "rails_helper"

RSpec.describe ChatTurnJob::HistoryFallback do
  # Lightweight doubles for message attributes. Kept outside let blocks so
  # they can be used across all example groups without recreation overhead.
  MsgDouble         = Struct.new(:role, :content, :tool_name, :proposal, :pending_action, keyword_init: true)
  ProposalDouble    = Struct.new(:slug, :state, :kind, :title, :materialized_label, keyword_init: true)
  PendingActDouble  = Struct.new(:action, :action_type, :state, keyword_init: true)

  let(:user)         { Factories.user }
  let(:repository)   { Factories.repository(user: user) }
  let(:chat)         { ChatSession.create!(user: user, repository: repository) }
  let(:user_message) { chat.messages.create!(role: "user", content: { "text" => "What next?" }) }

  # Build a host object that has the module's methods as singleton methods,
  # plus the @chat / @user_message instance variables the module reads.
  let(:host) do
    obj = Object.new
    obj.extend(ChatTurnJob::HistoryFallback)
    obj.instance_variable_set(:@chat, chat)
    obj.instance_variable_set(:@user_message, user_message)
    obj
  end

  # --- bounded_history_text ---------------------------------------------------

  describe "#bounded_history_text" do
    it "returns empty string for nil" do
      expect(host.send(:bounded_history_text, nil)).to eq("")
    end

    it "returns empty string for blank input" do
      expect(host.send(:bounded_history_text, "   ")).to eq("")
    end

    it "passes through text shorter than the byte limit unchanged" do
      expect(host.send(:bounded_history_text, "short")).to eq("short")
    end

    it "truncates text that exceeds the default byte limit" do
      long_text = "x" * (ChatTurnJob::HISTORY_FALLBACK_ENTRY_MAX_BYTES + 10)
      result = host.send(:bounded_history_text, long_text)
      expect(result).to end_with("...[truncated]")
      # The non-suffix portion must be at most the limit
      prefix = result.delete_suffix(" ...[truncated]")
      expect(prefix.bytesize).to be <= ChatTurnJob::HISTORY_FALLBACK_ENTRY_MAX_BYTES
    end

    it "respects a custom max_bytes override" do
      result = host.send(:bounded_history_text, "hello world", 5)
      expect(result).to end_with("...[truncated]")
      prefix = result.delete_suffix(" ...[truncated]")
      expect(prefix.bytesize).to be <= 5
    end

    it "does not truncate text at exactly the limit" do
      at_limit = "a" * ChatTurnJob::HISTORY_FALLBACK_ENTRY_MAX_BYTES
      expect(host.send(:bounded_history_text, at_limit)).to eq(at_limit)
    end
  end

  # --- bounded_history_entries ------------------------------------------------

  describe "#bounded_history_entries" do
    it "returns empty string for an empty list" do
      expect(host.send(:bounded_history_entries, [])).to eq("")
    end

    it "joins all entries with double newlines when they fit within the budget" do
      result = host.send(:bounded_history_entries, %w[first second third])
      expect(result).to eq("first\n\nsecond\n\nthird")
    end

    it "skips blank entries" do
      result = host.send(:bounded_history_entries, ["first", "", "  ", "third"])
      expect(result).to eq("first\n\nthird")
    end

    it "drops the oldest entries to stay within HISTORY_FALLBACK_MAX_BYTES" do
      # Build enough entries to exceed the budget (~200 bytes each × 80 = 16 KB > 12 KB).
      entry = "x" * 200
      many  = Array.new(80) { |i| "#{entry}-#{i}" }
      result = host.send(:bounded_history_entries, many)

      expect(result.bytesize).to be <= ChatTurnJob::HISTORY_FALLBACK_MAX_BYTES
      # The most recent entries survive.
      expect(result).to include(many.last)
    end

    it "returns entries in original (oldest-first) order" do
      result = host.send(:bounded_history_entries, %w[alpha beta gamma])
      expect(result.split("\n\n")).to eq(%w[alpha beta gamma])
    end
  end

  # --- chat_history_entry (user / assistant) ----------------------------------

  describe "#chat_history_entry for user and assistant messages" do
    it "renders a user message as 'user: {text}'" do
      msg = MsgDouble.new(role: "user", content: { "text" => "Hello" }, tool_name: nil, proposal: nil, pending_action: nil)
      expect(host.send(:chat_history_entry, msg)).to eq("user: Hello")
    end

    it "renders an assistant message as 'assistant: {text}'" do
      msg = MsgDouble.new(role: "assistant", content: "Response text", tool_name: nil, proposal: nil, pending_action: nil)
      expect(host.send(:chat_history_entry, msg)).to eq("assistant: Response text")
    end

    it "appends proposal_summary when the message has an attached proposal" do
      proposal = ProposalDouble.new(slug: "fix-auth", state: "confirmed", kind: "job", title: "Fix auth bug", materialized_label: nil)
      msg = MsgDouble.new(role: "user", content: { "text" => "See proposal" }, tool_name: nil, proposal: proposal, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("proposal_summary:")
      expect(result).to include("fix-auth")
      expect(result).to include("confirmed")
    end

    it "includes materialized label in proposal_summary when present" do
      proposal = ProposalDouble.new(slug: "add-feature", state: "materialized", kind: "job", title: "Add thing", materialized_label: "JOB-99")
      msg = MsgDouble.new(role: "user", content: { "text" => "Done" }, tool_name: nil, proposal: proposal, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("materialized=JOB-99")
    end

    it "appends pending_action summary when the message has an attached pending action" do
      action = PendingActDouble.new(action: "confirm_job", action_type: "confirm", state: "pending")
      msg = MsgDouble.new(role: "user", content: { "text" => "Action needed" }, tool_name: nil, proposal: nil, pending_action: action)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("pending_action: confirm_job state=pending")
    end

    it "falls back to action_type when action is blank" do
      action = PendingActDouble.new(action: nil, action_type: "confirm", state: "pending")
      msg = MsgDouble.new(role: "user", content: { "text" => "Act" }, tool_name: nil, proposal: nil, pending_action: action)
      expect(host.send(:chat_history_entry, msg)).to include("pending_action: confirm")
    end
  end

  # --- chat_history_entry (system) -------------------------------------------

  describe "#chat_history_entry for system messages" do
    def system_msg(text, source: nil)
      content = { "text" => text }
      content["source"] = source if source
      MsgDouble.new(role: "system", content: content, tool_name: nil, proposal: nil, pending_action: nil)
    end

    it "returns nil for unimportant system messages" do
      expect(host.send(:chat_history_entry, system_msg("Just an FYI"))).to be_nil
    end

    it "returns text for source=proposal_notification" do
      msg = system_msg("Proposal ABC confirmed", source: "proposal_notification")
      expect(host.send(:chat_history_entry, msg)).to eq("system: Proposal ABC confirmed")
    end

    it "returns text for source=grader_report" do
      msg = system_msg("Graders passed", source: "grader_report")
      expect(host.send(:chat_history_entry, msg)).to eq("system: Graders passed")
    end

    it "returns text for supervisor event messages" do
      msg = MsgDouble.new(
        role: "system",
        content: {
          "text" => "[CRITICAL] Workflow stalled\nRUN-42 has no heartbeat.",
          "supervisor_event" => { "kind" => "run_stalled", "severity" => "critical" }
        },
        tool_name: nil,
        proposal: nil,
        pending_action: nil
      )

      expect(host.send(:chat_history_entry, msg)).to include("system: [CRITICAL] Workflow stalled")
    end

    it "returns text for pending action outcome notifications" do
      msg = system_msg(
        "Pending action confirmed: retry_job (JOB-12). The action has been applied.",
        source: ChatPendingActionOutcomeNotification::SOURCE
      )
      expect(host.send(:chat_history_entry, msg)).to include("system: Pending action confirmed")
    end

    it "returns text for proposal lifecycle text patterns" do
      %w[confirmed rejected withdrawn created materialized].each do |verb|
        text = "Proposal \"Fix it\" #{verb}"
        expect(host.send(:chat_history_entry, system_msg(text))).to eq("system: #{text}"),
          "expected '#{text}' to be recognized as important"
      end
    end

    it "returns text for agent-event patterns" do
      ["Cancelled by operator", "Agent turn failed", "Agent turn completed",
       "MCP unavailable: sidecar not found", "Codex resume from session abc"].each do |text|
        expect(host.send(:chat_history_entry, system_msg(text))).to eq("system: #{text}"),
          "expected '#{text}' to be recognized as important"
      end
    end
  end

  # --- chat_history_entry (tool_use) -----------------------------------------

  describe "#chat_history_entry for tool_use messages" do
    it "renders 'tool_use: {name} {compact_input}' with filtered keys" do
      input = { "command" => "ls -la", "file_path" => "/app", "extra" => "ignored" }
      msg = MsgDouble.new(role: "tool_use", content: { "input" => input }, tool_name: "bash", proposal: nil, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to start_with("tool_use: bash")
      parsed = JSON.parse(result.split(" ", 3).last)
      expect(parsed).to include("command" => "ls -la", "file_path" => "/app")
      expect(parsed).not_to have_key("extra")
    end

    it "falls back to 'tool_use: {name}' when input is not a Hash" do
      msg = MsgDouble.new(role: "tool_use", content: { "input" => "plain string" }, tool_name: "some_tool", proposal: nil, pending_action: nil)
      expect(host.send(:chat_history_entry, msg)).to eq("tool_use: some_tool")
    end

    it "uses 'tool' as name when tool_name is blank" do
      msg = MsgDouble.new(role: "tool_use", content: {}, tool_name: nil, proposal: nil, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to start_with("tool_use: tool")
    end
  end

  # --- chat_history_entry (tool_result) --------------------------------------

  describe "#chat_history_entry for tool_result messages" do
    it "renders 'ok' status when is_error is false and content has text" do
      msg = MsgDouble.new(role: "tool_result", content: { "content" => "Done.", "is_error" => false }, tool_name: "read_file", proposal: nil, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("read_file ok: Done.")
    end

    it "renders 'error' status when is_error is true" do
      msg = MsgDouble.new(role: "tool_result", content: { "content" => "Not found", "is_error" => true }, tool_name: "read_file", proposal: nil, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("read_file error: Not found")
    end

    it "renders 'ok' with no body when content is empty" do
      msg = MsgDouble.new(role: "tool_result", content: { "is_error" => false }, tool_name: "some_tool", proposal: nil, pending_action: nil)
      expect(host.send(:chat_history_entry, msg)).to eq("tool_result: some_tool ok")
    end

    it "extracts text from an array of content blocks" do
      blocks = [{ "type" => "text", "text" => "Block result" }, { "type" => "image" }]
      msg = MsgDouble.new(role: "tool_result", content: { "content" => blocks, "is_error" => false }, tool_name: "view", proposal: nil, pending_action: nil)
      result = host.send(:chat_history_entry, msg)
      expect(result).to include("Block result")
    end
  end

  # --- important_system_message? ---------------------------------------------

  describe "#important_system_message?" do
    def check(text, source: nil)
      content = { "text" => text }
      content["source"] = source if source
      msg = MsgDouble.new(role: "system", content: content, tool_name: nil, proposal: nil, pending_action: nil)
      host.send(:important_system_message?, msg, text)
    end

    it "returns true for source=proposal_notification" do
      expect(check("anything", source: "proposal_notification")).to be(true)
    end

    it "returns true for source=grader_report" do
      expect(check("anything", source: "grader_report")).to be(true)
    end

    it "returns true for source=pending_action_notification" do
      expect(check("anything", source: ChatPendingActionOutcomeNotification::SOURCE)).to be(true)
    end

    it "returns true for supervisor_event content" do
      msg = MsgDouble.new(
        role: "system",
        content: { "text" => "event", "supervisor_event" => { "kind" => "queue_backlog" } },
        tool_name: nil,
        proposal: nil,
        pending_action: nil
      )

      expect(host.send(:important_system_message?, msg, "event")).to be(true)
    end

    it "returns true for proposal-lifecycle text (case-insensitive match)" do
      expect(check("Proposal \"Foo\" confirmed")).to be(true)
      expect(check("proposal \"Foo\" REJECTED")).to be(true)
    end

    it "returns true for agent-event text" do
      expect(check("Cancelled by operator due to timeout")).to be(true)
      expect(check("Agent turn failed after 200 turns")).to be(true)
      expect(check("Agent turn completed")).to be(true)
      expect(check("MCP unavailable: retrying")).to be(true)
      expect(check("Codex resume")).to be(true)
      expect(check("Pending action dismissed: rebase_job")).to be(true)
    end

    it "returns false for unrecognized system messages" do
      expect(check("Background context loaded")).to be(false)
      expect(check("Reminder: stay on topic")).to be(false)
      expect(check("")).to be(false)
    end
  end

  # --- tool_result_text -------------------------------------------------------

  describe "#tool_result_text" do
    it "returns nil for nil" do
      expect(host.send(:tool_result_text, nil)).to be_nil
    end

    it "returns the string directly for a String result" do
      expect(host.send(:tool_result_text, "plain text")).to eq("plain text")
    end

    it "extracts text blocks from an Array, skipping non-text entries" do
      blocks = [
        { "type" => "text", "text" => "part A" },
        { "type" => "image" },
        { "type" => "text", "text" => "part B" }
      ]
      expect(host.send(:tool_result_text, blocks)).to eq("part A\npart B")
    end

    it "returns nil for an empty array" do
      expect(host.send(:tool_result_text, [])).to be_nil
    end

    it "extracts known fields from a Hash and returns JSON" do
      result = { "status" => "ok", "message" => "Done", "irrelevant" => "ignored" }
      parsed = JSON.parse(host.send(:tool_result_text, result))
      expect(parsed).to include("status" => "ok", "message" => "Done")
      expect(parsed).not_to have_key("irrelevant")
    end

    it "returns nil for an unrecognized type (e.g. Integer)" do
      expect(host.send(:tool_result_text, 42)).to be_nil
    end
  end

  # --- compact_tool_input -----------------------------------------------------

  describe "#compact_tool_input" do
    it "returns nil for nil" do
      expect(host.send(:compact_tool_input, nil)).to be_nil
    end

    it "returns nil for a String" do
      expect(host.send(:compact_tool_input, "string")).to be_nil
    end

    it "returns nil for an Array" do
      expect(host.send(:compact_tool_input, [1, 2])).to be_nil
    end

    it "filters a Hash to the recognized key list" do
      input  = { "status" => "ok", "command" => "ls", "file_path" => "/x",
                 "title" => "T", "secret" => "dropped", "slug" => "s" }
      result = JSON.parse(host.send(:compact_tool_input, input))
      expect(result.keys).to match_array(%w[status command file_path title slug])
    end

    it "returns '{}' for a Hash with no recognized keys" do
      expect(host.send(:compact_tool_input, { "unknown" => "x" })).to eq("{}")
    end
  end

  # --- chat_history_fallback (integration) ------------------------------------

  describe "#chat_history_fallback" do
    before { user_message }  # ensure the excluded current message exists

    it "returns nil when there are no prior messages besides the current user message" do
      expect(host.chat_history_fallback).to be_nil
    end

    it "returns nil when all prior messages are filtered out (unimportant system messages)" do
      chat.messages.create!(role: "system", content: { "text" => "Background context" })
      expect(host.chat_history_fallback).to be_nil
    end

    it "builds a wrapped transcript from user and assistant messages" do
      chat.messages.create!(role: "user",      content: { "text" => "What is the plan?" })
      chat.messages.create!(role: "assistant", content: { "text" => "All is well." })

      result = host.chat_history_fallback
      expect(result).to include("Recent persisted chat context fallback:")
      expect(result).to include("Provider resume should still be attempted")
      expect(result).to include("user: What is the plan?")
      expect(result).to include("assistant: All is well.")
    end

    it "excludes the current user_message from the transcript" do
      chat.messages.create!(role: "assistant", content: { "text" => "Prior answer." })

      result = host.chat_history_fallback
      expect(result).to include("Prior answer.")
      expect(result).not_to include("What next?")  # user_message text
    end

    it "includes important system messages (grader_report) in the transcript" do
      chat.messages.create!(role: "system", content: { "text" => "Graders passed", "source" => "grader_report" })

      result = host.chat_history_fallback
      expect(result).not_to be_nil
      expect(result).to include("system: Graders passed")
    end

    it "includes supervisor event messages in the transcript" do
      chat.messages.create!(
        role: "system",
        content: {
          "text" => "[WARNING] Queue backlog\nThe runs queue has 18 pending entries.",
          "supervisor_event" => { "kind" => "queue_backlog", "severity" => "warning" }
        }
      )

      result = host.chat_history_fallback
      expect(result).not_to be_nil
      expect(result).to include("system: [WARNING] Queue backlog")
    end
  end
end
