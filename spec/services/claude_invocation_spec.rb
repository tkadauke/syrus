require "rails_helper"

RSpec.describe ClaudeInvocation do
  def result_fixture(**overrides)
    defaults = { turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil }
    AgentInvocation::Result.new(**defaults.merge(overrides), session_id: nil)
  end

  describe "#run" do
    it "delegates to the injected runner with all the kwargs" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture(turns: 2)
      }

      result = described_class.new("/tmp/wkt", prompt: "do the thing", oauth_token: "oat-x",
                                   runner: runner, timeout: 60, max_turns: 7).run

      expect(received[:workspace_path]).to eq("/tmp/wkt")
      expect(received[:prompt]).to eq("do the thing")
      expect(received[:oauth_token]).to eq("oat-x")
      expect(received[:timeout]).to eq(60)
      expect(received[:max_turns]).to eq(7)
      expect(received[:mcp_config]).to be_nil
      expect(received[:image_paths]).to eq([])
      expect(received[:file_paths]).to eq([])
      expect(received[:disallowed_tools]).to eq([])
      expect(received[:env]).to eq({})
      expect(received[:stop_requested].call).to eq(false)
      expect(received[:process_started]).to respond_to(:call)
      expect(result.turns).to eq(2)
      expect(result).to be_success
    end

    it "passes mcp_config through to the runner when set" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture
      }

      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x",
                          runner: runner, mcp_config: "/tmp/mcp.json").run

      expect(received[:mcp_config]).to eq("/tmp/mcp.json")
    end

    it "passes image and file paths through to the runner when set" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture
      }

      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x",
                          runner: runner,
                          image_paths: [ "/tmp/foo.png" ],
                          file_paths: [ "/tmp/bar.pdf" ]).run

      expect(received[:image_paths]).to eq([ "/tmp/foo.png" ])
      expect(received[:file_paths]).to eq([ "/tmp/bar.pdf" ])
    end

    it "passes extra environment through to the runner when set" do
      received = {}
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture
      }

      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x",
                          runner: runner,
                          env: { "GIT_ASKPASS" => "/tmp/askpass.sh", "GIT_TERMINAL_PROMPT" => "0" }).run

      expect(received[:env]).to eq(
        "GIT_ASKPASS" => "/tmp/askpass.sh",
        "GIT_TERMINAL_PROMPT" => "0"
      )
    end

    it "passes on_session_id callback through to the runner" do
      received_callback = nil
      runner = ->(**kwargs) {
        received_callback = kwargs[:on_session_id]
        result_fixture
      }
      callback = ->(_) {}
      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x",
                          runner: runner, on_session_id: callback).run
      expect(received_callback).to eq(callback)
    end

    it "defaults on_session_id to a no-op when not provided" do
      received_callback = nil
      runner = ->(**kwargs) {
        received_callback = kwargs[:on_session_id]
        result_fixture
      }
      described_class.new("/tmp/wkt", prompt: "x", oauth_token: "x", runner: runner).run
      expect(received_callback).to respond_to(:call)
      expect { received_callback.call("sid") }.not_to raise_error
    end
  end

  describe AgentInvocation::Result do
    it "is success when not timed out, exit_status 0, and not is_error" do
      r = described_class.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      expect(r).to be_success
    end

    it "is not success when timed_out" do
      r = described_class.new(turns: 30, exit_status: nil, timed_out: true, is_error: false, outcome: nil, final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end

    it "is not success when exit_status non-zero" do
      r = described_class.new(turns: 1, exit_status: 1, timed_out: false, is_error: false, outcome: nil, final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end

    it "is not success when is_error is true (e.g. error_max_turns)" do
      r = described_class.new(turns: 50, exit_status: 0, timed_out: false, is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      expect(r).not_to be_success
    end
  end

  describe "stream-json event parsing" do
    let(:lines) { [] }
    let(:invocation) { described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: ->(l, **_) { lines << l }) }

    it "extracts assistant text into the log_sink" do
      event = { type: "assistant", message: { content: [ { type: "text", text: "Looking at the issue..." } ] } }.to_json
      result = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(lines.last).to eq("Looking at the issue...")
      expect(result).to be_nil
    end

    it "emits thinking blocks with kind: thinking, thinking text, and signature" do
      events = []
      event = {
        type: "assistant",
        message: {
          content: [
            { type: "thinking", thinking: "Let me reason through this...", signature: "sig-abc123" },
            { type: "text", text: "Here is the answer." }
          ]
        }
      }.to_json

      invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(events).to eq([
        [ "Let me reason through this...", { kind: "thinking", thinking: "Let me reason through this...", signature: "sig-abc123" } ],
        [ "Here is the answer.", { kind: "assistant_text" } ]
      ])
    end

    it "does not emit empty thinking blocks" do
      events = []
      event = {
        type: "assistant",
        message: {
          content: [
            { type: "thinking", thinking: "", signature: "sig-abc123" },
            { type: "text", text: "Present." }
          ]
        }
      }.to_json

      invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(events.map { |_, kw| kw[:kind] }).to eq([ "assistant_text" ])
    end

    it "passes tool_use_id from the block id for tool_use events" do
      events = []
      event = {
        type: "assistant",
        message: {
          content: [
            { type: "tool_use", id: "toolu_abc123", name: "Read", input: { "file_path" => "/tmp/foo" } }
          ]
        }
      }.to_json

      invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(events.size).to eq(1)
      expect(events.first.last).to include(
        kind: "tool_call",
        tool_name: "Read",
        tool_input: { "file_path" => "/tmp/foo" },
        tool_use_id: "toolu_abc123"
      )
    end

    it "reports Claude API authentication failures as system errors instead of assistant text" do
      events = []
      event = {
        type: "assistant",
        error: "authentication_failed",
        isApiErrorMessage: true,
        apiErrorStatus: 401,
        message: {
          model: "<synthetic>",
          content: [
            { type: "text", text: "Failed to authenticate. API Error: 401 Invalid authentication credentials" }
          ]
        }
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to eq(is_error: true, outcome: "authentication_failed", final_text: nil)
      expect(events).to contain_exactly(
        [
          "Claude authentication failed. Refresh the Claude OAuth token in Credentials, then send the message again. (401 Failed to authenticate. API Error: 401 Invalid authentication credentials)",
          { kind: "system" }
        ]
      )
    end

    it "captures Claude usage-limit API errors as a distinct outcome" do
      events = []
      invocation = described_class.new(
        "/tmp",
        prompt: "x",
        oauth_token: "x",
        model: "claude-sonnet-4",
        log_sink: ->(_l, **_) {}
      )
      event = {
        type: "assistant",
        isApiErrorMessage: true,
        apiErrorStatus: 429,
        message: {
          content: [
            { type: "text", text: "Your monthly usage limit for model claude-sonnet-4 has been exhausted. Add credits to continue." }
          ]
        }
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to include(
        is_error: true,
        outcome: "provider_usage_limit",
        final_text: a_string_including("Claude API error", "monthly usage limit")
      )
      expect(events).to include([
        a_string_including("Claude API error", "monthly usage limit"),
        { kind: "system" }
      ])
    end

    it "captures Claude extra-usage exhaustion API errors as a usage-limit outcome" do
      events = []
      invocation = described_class.new(
        "/tmp",
        prompt: "x",
        oauth_token: "x",
        model: "claude-sonnet-4",
        log_sink: ->(_l, **_) {}
      )
      event = {
        type: "assistant",
        error: "rate_limit_error",
        isApiErrorMessage: true,
        apiErrorStatus: 429,
        message: {
          content: [
            { type: "text", text: "You're out of extra usage · resets 7am (America/New_York)" }
          ]
        }
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to include(
        is_error: true,
        outcome: "provider_usage_limit",
        final_text: a_string_including("Claude API error", "out of extra usage", "resets 7am")
      )
      expect(events).to include([
        a_string_including("Claude API error", "out of extra usage", "resets 7am"),
        { kind: "system" }
      ])
    end

    it "captures num_turns + is_error + outcome from the result event" do
      event = { type: "result", num_turns: 5, duration_ms: 12345, is_error: false, subtype: "success" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to eq(turns: 5, is_error: false, outcome: "success", final_text: nil)
      expect(lines.last).to match(/subtype=success/).and match(/turns=5/)
    end

    it "captures cost and token usage from the result event" do
      event = {
        type: "result",
        num_turns: 5,
        duration_ms: 12345,
        is_error: false,
        subtype: "success",
        total_cost_usd: 0.1234,
        usage: {
          input_tokens: 100,
          output_tokens: 20,
          cache_creation_input_tokens: 30,
          cache_read_input_tokens: 400
        }
      }.to_json

      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })

      expect(update).to include(
        cost_usd: 0.1234,
        input_tokens: 100,
        output_tokens: 20,
        cache_creation_input_tokens: 30,
        cache_read_input_tokens: 400
      )
    end

    it "captures error subtype on max-turns" do
      event = { type: "result", num_turns: 50, is_error: true, subtype: "error_max_turns" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to include(is_error: true, outcome: "error_max_turns", final_text: nil)
    end

    it "passes non-JSON lines through verbatim" do
      result = invocation.send(:process_event, "not json", ->(l, **_) { lines << l })
      expect(lines.last).to eq("not json")
      expect(result).to be_nil
    end

    it "ignores unknown event types" do
      event = { type: "unknown", foo: "bar" }.to_json
      result = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(lines).to be_empty
      expect(result).to be_nil
    end

    it "captures session_id from the system/init event" do
      event = { type: "system", subtype: "init", session_id: "abc-123-xyz", cwd: "/x" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to eq(session_id: "abc-123-xyz")
    end

    it "streams structured MCP server health from the system/init event" do
      events = []
      event = {
        type: "system",
        subtype: "init",
        session_id: "abc-123-xyz",
        mcp_servers: [
          { "name" => "syrus-chat-sidecar", "status" => "pending" }
        ]
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to eq(session_id: "abc-123-xyz")
      expect(events).to contain_exactly(
        [
          "[mcp_servers] syrus-chat-sidecar=pending",
          {
            kind: "system",
            mcp_servers: [ { "name" => "syrus-chat-sidecar", "status" => "pending" } ]
          }
        ]
      )
    end

    it "allows pending MCP sidecar init to keep booting when a tool is required" do
      invocation = described_class.new(
        "/tmp",
        prompt: "x",
        oauth_token: "x",
        required_mcp_tools: %w[submit_adversarial_review]
      )
      events = []
      event = {
        type: "system",
        subtype: "init",
        session_id: "abc-123-xyz",
        mcp_servers: [
          { "name" => "syrus-mcp-sidecar", "status" => "pending" }
        ]
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to eq(session_id: "abc-123-xyz")
      expect(events).to include(
        [
          "[mcp_servers] syrus-mcp-sidecar=pending",
          {
            kind: "system",
            mcp_servers: [ { "name" => "syrus-mcp-sidecar", "status" => "pending" } ]
          }
        ]
      )
    end

    it "marks missing required MCP sidecar init as a failure" do
      invocation = described_class.new(
        "/tmp",
        prompt: "x",
        oauth_token: "x",
        required_mcp_tools: %w[submit_test_plan]
      )
      events = []
      event = {
        type: "system",
        subtype: "init",
        session_id: "abc-123-xyz",
        mcp_servers: []
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to eq(
        session_id: "abc-123-xyz",
        mcp_server_failed: true,
        is_error: true,
        outcome: "mcp_sidecar_failed",
        final_text: nil
      )
      expect(events).to include(
        [
          "[mcp_required] syrus-mcp-sidecar=missing; required tools unavailable: submit_test_plan",
          { kind: "system" }
        ]
      )
    end

    it "accepts connected MCP sidecar init when a tool is required" do
      invocation = described_class.new(
        "/tmp",
        prompt: "x",
        oauth_token: "x",
        required_mcp_tools: %w[submit_summary]
      )
      event = {
        type: "system",
        subtype: "init",
        session_id: "abc-123-xyz",
        mcp_servers: [
          { "name" => "syrus-mcp-sidecar", "status" => "connected" }
        ]
      }.to_json

      update = invocation.send(:process_event, event, ->(_line, **_) { })

      expect(update).to eq(session_id: "abc-123-xyz")
    end

    it "marks failed MCP server init as an MCP sidecar failure" do
      events = []
      event = {
        type: "system",
        subtype: "init",
        session_id: "abc-123-xyz",
        mcp_servers: [
          { "name" => "syrus-mcp-sidecar", "status" => "failed" }
        ]
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to eq(
        session_id: "abc-123-xyz",
        mcp_server_failed: true,
        is_error: true,
        outcome: "mcp_sidecar_failed",
        final_text: nil
      )
      expect(events).to contain_exactly(
        [
          "[mcp_servers] syrus-mcp-sidecar=failed",
          {
            kind: "system",
            mcp_servers: [ { "name" => "syrus-mcp-sidecar", "status" => "failed" } ]
          }
        ]
      )
    end

    it "ignores other system subtypes (only system/init carries the session_id we need)" do
      event = { type: "system", subtype: "other", session_id: "xxx" }.to_json
      update = invocation.send(:process_event, event, ->(l, **_) { lines << l })
      expect(update).to be_nil
    end
  end

  describe "provider cleanup timeout handling" do
    let(:successful_result_line) do
      { type: "result", num_turns: 3, is_error: false, subtype: "success",
        total_cost_usd: 0.05, usage: {} }.to_json
    end

    def stub_process_runner(runner_result, emit_line: nil, emit_lines: nil)
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        fake = double("ProcessRunner")
        allow(fake).to receive(:run) do
          Array(emit_lines || emit_line).compact.each do |line|
            kwargs[:on_output_line]&.call(line)
          end
          runner_result
        end
        fake
      end
    end

    def silent_timeout_result
      ProcessRunner::Result.new(
        exit_status: nil, timed_out: false, stopped: false, silent_timed_out: true,
        operator_killed: false, aliveness_failed: false, duration_s: 1234.5, spawned_process_id: nil
      )
    end

    def wall_timeout_result
      ProcessRunner::Result.new(
        exit_status: nil, timed_out: true, stopped: false, silent_timed_out: false,
        operator_killed: false, aliveness_failed: false, duration_s: 5400.0, spawned_process_id: nil
      )
    end

    let(:null_sink) { ->(_chunk, **) { } }

    it "treats a silent timeout after a successful provider result as cleanup overhead" do
      invocation = described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: null_sink)
      stub_process_runner(silent_timeout_result, emit_line: successful_result_line)

      result = invocation.run

      expect(result).to be_success
      expect(result.timed_out).to be false
      expect(result.exit_status).to eq(0)
      expect(result.outcome).to eq("success")
      expect(result.turns).to eq(3)
    end

    it "treats a wall-clock timeout after a successful provider result as cleanup overhead" do
      invocation = described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: null_sink)
      stub_process_runner(wall_timeout_result, emit_line: successful_result_line)

      result = invocation.run

      expect(result).to be_success
      expect(result.timed_out).to be false
      expect(result.exit_status).to eq(0)
    end

    it "still surfaces a silent timeout when no provider result was received" do
      invocation = described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: null_sink)
      stub_process_runner(silent_timeout_result)

      result = invocation.run

      expect(result).not_to be_success
      expect(result.timed_out).to be true
      expect(result.exit_status).to be_nil
    end

    it "still surfaces a timeout when the provider result was an error" do
      error_result_line = { type: "result", num_turns: 50, is_error: true,
                            subtype: "error_max_turns", usage: {} }.to_json
      invocation = described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: null_sink)
      stub_process_runner(silent_timeout_result, emit_line: error_result_line)

      result = invocation.run

      expect(result).not_to be_success
      expect(result.timed_out).to be true
      expect(result.is_error).to be true
    end

    it "preserves a streamed API error when Claude later emits an error result with subtype success" do
      api_error_line = {
        type: "assistant",
        isApiErrorMessage: true,
        message: {
          content: [
            { type: "text", text: "Prompt is too long" }
          ]
        }
      }.to_json
      result_line = {
        type: "result",
        num_turns: 3,
        is_error: true,
        subtype: "success",
        usage: {}
      }.to_json
      invocation = described_class.new("/tmp", prompt: "x", oauth_token: "x", log_sink: null_sink)
      stub_process_runner(silent_timeout_result, emit_lines: [ api_error_line, result_line ])

      result = invocation.run

      expect(result).not_to be_success
      expect(result.is_error).to be true
      expect(result.outcome).to eq("api_error")
    end
  end

  describe "default_runner cmd line ordering" do
    # The prompt is sent over stdin, never on argv (a large prompt on argv
    # overruns MAX_ARG_STRLEN and execve fails with Errno::E2BIG). This pins
    # that: the prompt string must not appear anywhere in the command, and
    # --mcp-config must still be followed by another flag (no trailing
    # positional that its variadic could swallow).
    it "keeps the prompt off argv and never leaves --mcp-config trailing" do
      invocation = described_class.new("/tmp", prompt: "PROMPT_BODY", oauth_token: "x",
                                       mcp_config: "/tmp/mcp.json")

      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run

      expect(cmd).not_to include("PROMPT_BODY")   # prompt travels over stdin
      mcp_idx = cmd.index("--mcp-config")
      expect(mcp_idx).not_to be_nil, "expected --mcp-config in cmd: #{cmd.inspect}"
      expect(cmd[mcp_idx + 1]).to eq("/tmp/mcp.json")
      expect(cmd[mcp_idx + 2]).to start_with("--"),
        "arg after mcp-config path must be another flag, not a positional — got #{cmd[mcp_idx + 2].inspect}"
    end

    it "delivers the prompt to ProcessRunner as stdin_data, not in the command" do
      captured = {}
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured[:command] = kwargs[:command]
        captured[:stdin_data] = kwargs[:stdin_data]
        fake = double("ProcessRunner")
        allow(fake).to receive(:run).and_return(
          ProcessRunner::Result.new(
            exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false,
            operator_killed: false, aliveness_failed: false, duration_s: 1.0, spawned_process_id: nil
          )
        )
        fake
      end

      described_class.new("/tmp", prompt: "A HUGE PROMPT BODY", oauth_token: "x").run

      expect(captured[:stdin_data]).to eq("A HUGE PROMPT BODY")
      expect(captured[:command]).not_to include("A HUGE PROMPT BODY")
    end

    it "passes --resume <id> when resume_session_id is set" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x",
                                       resume_session_id: "abc-123")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run

      idx = cmd.index("--resume")
      expect(idx).not_to be_nil, "expected --resume in cmd: #{cmd.inspect}"
      expect(cmd[idx + 1]).to eq("abc-123")
      expect(cmd[idx + 2]).to start_with("--"), "arg after resume id must be another flag — got #{cmd[idx + 2].inspect}"
    end

    it "passes --disallowedTools before the output flags when tools are denied" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x",
                                       disallowed_tools: %w[Write Edit MultiEdit])
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run

      idx = cmd.index("--disallowedTools")
      expect(idx).not_to be_nil
      expect(cmd[idx + 1, 3]).to eq(%w[Write Edit MultiEdit])
      expect(cmd[idx + 4]).to start_with("--"), "arg after disallowed tool list must be another flag — got #{cmd[idx + 4].inspect}"
    end

    it "passes file flags before --output-format and omits unsupported image flags" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x",
                                       image_paths: [ "/tmp/foo.png" ],
                                       file_paths: [ "/tmp/bar.pdf" ])
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run

      image_idx = cmd.index("--image")
      file_idx = cmd.index("--file")
      output_idx = cmd.index("--output-format")
      expect(image_idx).to be_nil, "expected no --image in cmd: #{cmd.inspect}"
      expect(file_idx).not_to be_nil, "expected --file in cmd: #{cmd.inspect}"
      expect(cmd[file_idx + 1]).to eq("/tmp/bar.pdf")
      expect(file_idx).to be < output_idx
    end

    it "omits --resume when resume_session_id is nil (default)" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--resume")
    end

    it "passes --max-turns <n> when max_turns is positive" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: 42)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      idx = cmd.index("--max-turns")
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq("42")
    end

    it "omits --max-turns entirely when max_turns is 0 (operator opted out of the cap)" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: 0)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--max-turns")
    end

    it "omits --max-turns when max_turns is nil" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", max_turns: nil)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--max-turns")
    end

    it "passes --effort <level> when effort_level is set to a non-none value" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", effort_level: "high")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      idx = cmd.index("--effort")
      expect(idx).not_to be_nil
      expect(cmd[idx + 1]).to eq("high")
    end

    it "omits --effort when effort_level is nil" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", effort_level: nil)
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--effort")
    end

    it "omits --effort when effort_level is 'none'" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x", effort_level: "none")
      cmd = []
      allow(Open3).to receive(:popen2e) do |_env, *args, **_opts, &blk|
        cmd.replace(args)
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end

      invocation.run
      expect(cmd).not_to include("--effort")
    end
  end

  describe "agent env isolation (issue #104)" do
    # Stash + restore process-wide ENV so each example sees the same
    # baseline. ENV is global state; we set a worker-pod-like baseline,
    # run the example, then restore. Avoids depending on the host's
    # actual env for assertions.
    let(:saved_env) { ENV.to_h }
    let(:worker_baseline) do
      {
        # Worker-pod-like leakers we expect Syrus to STRIP:
        "BUNDLE_GEMFILE"          => "/rails/Gemfile",
        "BUNDLE_PATH"             => "/usr/local/bundle",
        "BUNDLE_DEPLOYMENT"       => "1",
        "BUNDLE_WITHOUT"          => "development:test",
        "GEM_HOME"                => "/usr/local/bundle",
        "GEM_PATH"                => "/usr/local/bundle",
        "RAILS_ENV"               => "production",
        "RAILS_MASTER_KEY"        => "should-never-leak",
        "SYRUS_DATABASE_PASSWORD" => "also-should-never-leak",
        # Allowlisted vars Syrus should FORWARD:
        "HOME"                    => "/home/rails",
        "PATH"                    => "/usr/local/bin:/usr/bin:/bin",
        "LANG"                    => "C.UTF-8"
      }
    end

    before do
      ENV.replace(saved_env.merge(worker_baseline))
    end
    after { ENV.replace(saved_env) }

    # Capture env + spawn opts so we can assert on them.
    def with_capturing_popen
      captured = { env: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *_args, **opts, &blk|
        captured[:env] = env
        captured[:opts] = opts
        rd, wr = IO.pipe; wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call(File.open(File::NULL, "w"), rd, fake_wait)
        rd.close
      end
      yield
      captured
    end

    it "passes unsetenv_others: true so the worker env doesn't leak into the agent" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      expect(result[:opts][:unsetenv_others]).to be true
    end

    it "drops worker container's Rails/Gem env and uses workspace-local Bundler paths" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      env = result[:env]
      %w[BUNDLE_GEMFILE BUNDLE_DEPLOYMENT BUNDLE_WITHOUT
         GEM_HOME GEM_PATH RAILS_ENV RAILS_MASTER_KEY SYRUS_DATABASE_PASSWORD].each do |k|
        expect(env).not_to have_key(k), "expected #{k.inspect} to be stripped from agent env, got #{env.inspect}"
      end
      expect(env["BUNDLE_PATH"]).to eq("/tmp/.syrus/deps/bundle")
      expect(env["BUNDLE_APP_CONFIG"]).to eq("/tmp/.syrus/deps/bundle-config")
    end

    it "forwards CLAUDE_CODE_OAUTH_TOKEN" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "oat-secret")
      result = with_capturing_popen { invocation.run }
      expect(result[:env]["CLAUDE_CODE_OAUTH_TOKEN"]).to eq("oat-secret")
    end

    it "forwards a curated allowlist of basic shell vars" do
      invocation = described_class.new("/tmp", prompt: "P", oauth_token: "x")
      result = with_capturing_popen { invocation.run }
      env = result[:env]
      expect(env["HOME"]).to eq("/home/rails")
      expect(env["PATH"]).to eq("/usr/local/bin:/usr/bin:/bin")
      expect(env["LANG"]).to eq("C.UTF-8")
    end

    it "sets BUNDLE_GEMFILE to the worktree's Gemfile when one exists" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
        invocation = described_class.new(dir, prompt: "P", oauth_token: "x")
        result = with_capturing_popen { invocation.run }
        expect(result[:env]["BUNDLE_GEMFILE"]).to eq(File.join(dir, "Gemfile"))
        expect(result[:env]["BUNDLE_PATH"]).to eq(File.join(dir, ".syrus", "deps", "bundle"))
      end
    end

    it "leaves BUNDLE_GEMFILE unset when the worktree has no Gemfile (non-Ruby project)" do
      Dir.mktmpdir do |dir|
        invocation = described_class.new(dir, prompt: "P", oauth_token: "x")
        result = with_capturing_popen { invocation.run }
        expect(result[:env]).not_to have_key("BUNDLE_GEMFILE")
      end
    end
  end

  describe "cross-pod session restore (#ensure_session_on_disk)" do
    let(:home_dir) { Dir.mktmpdir }
    let(:workspace_path) { File.join(home_dir, ".syrus", "workflows", "99") }
    let(:session_id) { "abc-cross-pod-#{SecureRandom.hex(4)}" }
    let(:log_lines) { [] }
    let(:log_sink) { ->(msg, **) { log_lines << msg } }
    let(:invocation) { described_class.new(workspace_path, prompt: "x", oauth_token: "x") }

    around do |example|
      saved = ENV["HOME"]
      ENV["HOME"] = home_dir
      example.run
    ensure
      ENV["HOME"] = saved
      FileUtils.rm_rf(home_dir)
    end

    def expected_path
      ClaudeSession.canonical_path_for(home: home_dir, cwd: workspace_path, session_id: session_id)
    end

    it "writes the transcript to disk when session is in DB but file is missing" do
      run = Factories.job.initial_run
      ClaudeSession.create!(resumable: run, session_id: session_id, transcript_jsonl: "{\"type\":\"system\"}\n")

      invocation.send(:ensure_session_on_disk, session_id, workspace_path, log_sink)

      expect(File.exist?(expected_path)).to be true
      expect(File.read(expected_path)).to eq("{\"type\":\"system\"}\n")
      expect(log_lines).to include(a_string_matching(/restored session.*from DB/))
    end

    it "is a no-op when the file already exists on disk (same-pod resume)" do
      run = Factories.job.initial_run
      ClaudeSession.create!(resumable: run, session_id: session_id, transcript_jsonl: "db content")
      FileUtils.mkdir_p(File.dirname(expected_path))
      File.write(expected_path, "existing disk content")

      invocation.send(:ensure_session_on_disk, session_id, workspace_path, log_sink)

      expect(File.read(expected_path)).to eq("existing disk content")
      expect(log_lines).to be_empty
    end

    it "is a no-op when session is not in DB" do
      invocation.send(:ensure_session_on_disk, session_id, workspace_path, log_sink)

      expect(File.exist?(expected_path)).to be false
      expect(log_lines).to be_empty
    end

    it "is a no-op when session is in DB but transcript_jsonl is nil" do
      run = Factories.job.initial_run
      ClaudeSession.create!(resumable: run, session_id: session_id, transcript_jsonl: nil)

      invocation.send(:ensure_session_on_disk, session_id, workspace_path, log_sink)

      expect(File.exist?(expected_path)).to be false
      expect(log_lines).to be_empty
    end

    it "logs a warning and does not raise when disk write fails" do
      run = Factories.job.initial_run
      ClaudeSession.create!(resumable: run, session_id: session_id, transcript_jsonl: "{}")
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES, "Permission denied")

      expect { invocation.send(:ensure_session_on_disk, session_id, workspace_path, log_sink) }.not_to raise_error
      expect(log_lines).to include(a_string_matching(/session restore failed.*Permission denied/))
    end

    it "restores the session file before spawning the subprocess" do
      run = Factories.job.initial_run
      sid = "spawn-order-test-#{SecureRandom.hex(4)}"
      ClaudeSession.create!(resumable: run, session_id: sid, transcript_jsonl: "{\"v\":1}\n")
      expected = ClaudeSession.canonical_path_for(home: home_dir, cwd: workspace_path, session_id: sid)
      file_existed_at_spawn = nil

      allow(Open3).to receive(:popen2e) do |_env, *_args, **_opts, &blk|
        file_existed_at_spawn = File.exist?(expected)
        rd, wr = IO.pipe
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      described_class.new(workspace_path, prompt: "x", oauth_token: "x",
                          log_sink: ->(_msg, **) {},
                          resume_session_id: sid).run

      expect(file_existed_at_spawn).to be true
      expect(File.read(expected)).to eq("{\"v\":1}\n")
    end
  end
end
