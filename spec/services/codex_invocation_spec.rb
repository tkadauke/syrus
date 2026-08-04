require "rails_helper"
require "tmpdir"

RSpec.describe CodexInvocation do
  def result_fixture(**overrides)
    defaults = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: "thread-1"
    }
    AgentInvocation::Result.new(**defaults.merge(overrides))
  end

  describe "#run" do
    it "delegates to the injected runner with all kwargs" do
      received = {}
      startup_timing = described_class::StartupTiming.new(source: "spec", sink: ->(_) { })
      runner = ->(**kwargs) {
        received.merge!(kwargs)
        result_fixture
      }

      result = described_class.new("/tmp/wkt",
                                   prompt: "do it",
                                   api_key: "sk-test",
                                   runner: runner,
                                   codex_home: "/tmp/codex-home",
                                   mcp_server: { command: "sidecar", args: [] },
                                   resume_session_id: "abc",
                                   resume_transcript_jsonl: "jsonl",
                                   startup_timing: startup_timing).run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        api_key: "sk-test",
        codex_home: "/tmp/codex-home",
        resume_session_id: "abc",
        resume_transcript_jsonl: "jsonl",
        model: "gpt-5.5",
        startup_timing: startup_timing
      )
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    def capture_popen(invocation, lines: nil, exitstatus: 0)
      captured = { env: nil, cmd: nil, opts: nil, stdin: nil }
      allow(Open3).to receive(:popen2e) do |env, *args, **opts, &blk|
        captured[:env] = env
        captured[:cmd] = args
        captured[:opts] = opts
        in_rd, in_wr = IO.pipe
        rd, wr = IO.pipe
        (lines || [
          { type: "thread.started", thread_id: "019e-test" },
          { type: "item.completed", item: { type: "agent_message", text: "done" } },
          { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 2, reasoning_output_tokens: 0, cached_input_tokens: 3 } }
        ]).each do |line|
          wr.write(line.is_a?(String) ? line : line.to_json)
          wr.write("\n")
        end
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(exitstatus), 0)
        blk.call(in_wr, rd, fake_wait)
        rd.close
        # The invocation's stdin writer thread is joined inside blk.call, so the
        # prompt is fully written and in_wr closed by now — safe to read it.
        captured[:stdin] = in_rd.read
        in_rd.close
      end

      result = invocation.run
      [ captured, result ]
    end

    it "runs codex exec with permission checks disabled" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: Pathname.new(home))
        captured, = capture_popen(invocation)

        expect(captured[:env]["CODEX_HOME"]).to eq(home)
        expect(captured[:cmd]).to include("codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--json")
        expect(captured[:cmd]).to include("--cd", "/tmp/wkt")
        # Prompt goes to stdin via the `-` sentinel, not on argv (argv-too-long
        # / Errno::E2BIG guard). "P" must not appear as a positional.
        expect(captured[:cmd].last).to eq("-")
        expect(captured[:cmd]).not_to include("P")
        expect(captured[:stdin]).to eq("P")
        expect(File.read(File.join(home, "config.toml"))).to include('model = "gpt-5.5"')
      end
    end

    it "allows the Codex model to be overridden by environment" do
      old_model = ENV["SYRUS_CODEX_MODEL"]
      ENV["SYRUS_CODEX_MODEL"] = "gpt-5.4"

      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)

        capture_popen(invocation)

        expect(File.read(File.join(home, "config.toml"))).to include('model = "gpt-5.4"')
      end
    ensure
      ENV["SYRUS_CODEX_MODEL"] = old_model
    end

    it "runs codex exec resume when resume_session_id is set" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home, resume_session_id: "019e-test")
        captured, = capture_popen(invocation)

        expect(captured[:cmd][0, 3]).to eq(%w[codex exec resume])
        expect(captured[:cmd]).to include("--dangerously-bypass-approvals-and-sandbox", "--json", "019e-test", "-")
        expect(captured[:cmd]).not_to include("--cd")
        expect(captured[:cmd]).not_to include("P")   # prompt is on stdin, not argv
        expect(captured[:stdin]).to eq("P")
      end
    end

    it "restores a captured rollout JSONL before resume when CODEX_HOME no longer has it" do
      Dir.mktmpdir do |home|
        jsonl = { type: "session_meta", payload: { id: "019e-test" } }.to_json + "\n"
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test",
                                         resume_transcript_jsonl: jsonl)
        _, result = capture_popen(invocation)

        restored = Dir.glob(File.join(home, "sessions", "**", "*019e-test.jsonl"))
        expect(restored.size).to eq(1)
        expect(File.read(restored.first)).to eq(jsonl)
        expect(result.transcript_path).to eq(restored.first)
      end
    end

    it "logs when a resumed Codex session has no rollout JSONL to restore" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-missing",
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        capture_popen(invocation)

        expect(events).to include([
          "[codex resume] no stored rollout JSONL for session 019e-missing; provider resume may be rejected or incomplete",
          { kind: "system" }
        ])
      end
    end

    it "logs when a Codex resume turn fails" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-gone",
                                         resume_transcript_jsonl: "{}\n",
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        _, result = capture_popen(
          invocation,
          lines: [
            { type: "thread.started", thread_id: "019e-gone" },
            { type: "turn.failed", error: "session not found" }
          ],
          exitstatus: 1
        )

        expect(result).not_to be_success
        expect(events).to include([
          "[codex error] session not found",
          { kind: "system" }
        ])
        expect(events).to include([
          "[codex resume] resume for session 019e-gone did not complete successfully: session not found",
          { kind: "system" }
        ])
      end
    end

    it "uses CODEX_HOME and CODEX_API_KEY while stripping worker Rails/Bundler env" do
      saved = ENV.to_h
      ENV["RAILS_MASTER_KEY"] = "do-not-leak"
      ENV["BUNDLE_GEMFILE"] = "/rails/Gemfile"
      ENV["PATH"] = "/usr/bin"

      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)
        captured, = capture_popen(invocation)

        expect(captured[:env]["CODEX_HOME"]).to eq(home)
        expect(captured[:env]["CODEX_API_KEY"]).to eq("sk-test")
        expect(captured[:env]["PATH"]).to eq("/usr/bin")
        expect(captured[:env]["BUNDLE_PATH"]).to eq("/tmp/wkt/.syrus/deps/bundle")
        expect(captured[:env]).not_to have_key("RAILS_MASTER_KEY")
        expect(captured[:env]).not_to have_key("BUNDLE_GEMFILE")
        expect(captured[:opts][:unsetenv_others]).to be true
      end
    ensure
      ENV.replace(saved)
    end

    it "writes a Codex config.toml for the Syrus MCP sidecar without putting env in argv" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          api_key: "sk-test",
          codex_home: home,
          mcp_server: {
            command: "/app/bin/syrus-mcp-sidecar",
            args: [ "--run-id", "12" ],
            env: { "RAILS_ENV" => "test", "RAILS_MASTER_KEY" => "secret" }
          }
        )
        captured, = capture_popen(invocation)

        config = File.read(File.join(home, "config.toml"))
        expect(config).to include('cli_auth_credentials_store = "file"')
        expect(config).to include('model = "gpt-5.5"')
        expect(config).to include('[mcp_servers.syrus-mcp-sidecar]')
        expect(config).to include('command = "/app/bin/syrus-mcp-sidecar"')
        expect(config).to include('args = ["--run-id", "12"]')
        expect(config).to include("required = true")
        expect(config).to include("startup_timeout_sec = 60")
        expect(config).to include("tool_timeout_sec = 60")
        expect(config).to include('[mcp_servers.syrus-mcp-sidecar.env]')
        expect(config).to include('RAILS_ENV = "test"')
        expect(config).to include('RAILS_MASTER_KEY = "secret"')
        expect(captured[:cmd].join(" ")).not_to include("RAILS_MASTER_KEY")
      end
    end

    it "writes named Codex MCP server blocks for chat sidecars" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          api_key: "sk-test",
          codex_home: home,
          mcp_servers: {
            "syrus-chat-sidecar" => {
              command: "/app/bin/syrus-chat-sidecar",
              args: [ "--tier", "essential" ],
              env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "essential" },
              required: true
            },
            "syrus-chat-deferred-sidecar" => {
              command: "/app/bin/syrus-chat-sidecar",
              args: [ "--tier", "deferred" ],
              env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "deferred" },
              required: false
            }
          }
        )

        capture_popen(invocation)

        config = File.read(File.join(home, "config.toml"))
        expect(config).to include("[mcp_servers.syrus-chat-sidecar]")
        expect(config).to include('command = "/app/bin/syrus-chat-sidecar"')
        expect(config).to include('args = ["--tier", "essential"]')
        expect(config).to include("required = true")
        expect(config).to include("[mcp_servers.syrus-chat-sidecar.env]")
        expect(config).to include('SYRUS_CHAT_MCP_TOOL_TIER = "essential"')
        expect(config).to include("[mcp_servers.syrus-chat-deferred-sidecar]")
        expect(config).to include('command = "/app/bin/syrus-chat-sidecar"')
        expect(config).to include('args = ["--tier", "deferred"]')
        expect(config).to include("required = false")
        expect(config).to include("[mcp_servers.syrus-chat-deferred-sidecar.env]")
        expect(config).to include('SYRUS_CHAT_MCP_TOOL_TIER = "deferred"')
      end
    end

    it "overwrites stale MCP config when no sidecar is requested" do
      Dir.mktmpdir do |home|
        File.write(File.join(home, "config.toml"), "[mcp_servers.syrus-mcp-sidecar]\ncommand = \"stale\"\n")
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)

        capture_popen(invocation)

        config = File.read(File.join(home, "config.toml"))
        expect(config).to include('cli_auth_credentials_store = "file"')
        expect(config).to include('approval_policy = "never"')
        expect(config).to include('model = "gpt-5.5"')
        expect(config).not_to include("[mcp_servers.syrus-mcp-sidecar]")
        expect(config).not_to include("stale")
      end
    end

    it "does not rewrite an unchanged Codex config" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)
        capture_popen(invocation)

        config_path = File.join(home, "config.toml")
        expect(File).not_to receive(:write).with(config_path, anything)

        capture_popen(invocation)
      end
    end

    it "emits startup timing diagnostics for spawn, MCP startup, and first output" do
      Dir.mktmpdir do |home|
        events = []
        timing = described_class::StartupTiming.new(source: "spec", sink: ->(event) { events << event })
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          api_key: "sk-test",
          codex_home: home,
          startup_timing: timing,
          mcp_servers: {
            "syrus-chat-sidecar" => {
              command: "/app/bin/syrus-chat-sidecar",
              args: [],
              env: {},
              required: true
            }
          }
        )

        capture_popen(invocation, lines: [
          { type: "thread.started", thread_id: "019e-test" },
          {
            type: "item.started",
            item: {
              type: "mcp_tool_call",
              server: "syrus-chat-sidecar",
              tool: "repo_info",
              arguments: {},
              call_id: "call_1"
            }
          },
          { type: "item.completed", item: { type: "agent_message", text: "done" } },
          { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 2 } }
        ])

        expect(events.join("\n")).to include(
          'stage="codex_home_prepare"',
          'stage="config_write"',
          'stage="transcript_restore"',
          'stage="process_spawn"',
          'stage="first_agent_event"',
          'stage="mcp_startup"',
          'stage="first_agent_message"'
        )
      end
    end

    it "parses JSONL events into the common AgentInvocation::Result shape" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)
        _, result = capture_popen(invocation)

        expect(result.session_id).to eq("019e-test")
        expect(result.turns).to eq(1)
        expect(result.outcome).to eq("success")
        expect(result.final_text).to eq("done")
        expect(result.input_tokens).to eq(1)
        expect(result.output_tokens).to eq(2)
        expect(result.cache_creation_input_tokens).to be_nil
        expect(result.cache_read_input_tokens).to eq(3)
        expect(result).to be_success
      end
    end

    it "surfaces non-JSON Codex startup failures in the result summary" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home,
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        _, result = capture_popen(
          invocation,
          lines: [
            "error: failed to refresh model metadata: unknown variant `max`, expected one of `low`, `medium`, `high`, `xhigh`"
          ],
          exitstatus: 1
        )

        expect(result).not_to be_success
        expect(result.is_error).to be true
        expect(result.outcome).to eq("error")
        expect(result.final_text).to include("unknown variant `max`")
        expect(events).to include([
          "error: failed to refresh model metadata: unknown variant `max`, expected one of `low`, `medium`, `high`, `xhigh`",
          {}
        ])
      end
    end
  end

  describe "provider cleanup timeout handling" do
    let(:null_sink) { ->(_chunk, **) {} }

    def stub_process_runner(runner_result, emit_line: nil)
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        fake = double("ProcessRunner")
        allow(fake).to receive(:run) do
          kwargs[:on_output_line]&.call(emit_line) if emit_line
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

    it "treats a silent timeout after a successful provider result as cleanup overhead" do
      turn_completed_line = {
        type: "turn.completed", usage: { input_tokens: 5, output_tokens: 10 }
      }.to_json
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "x", api_key: "sk-test",
                                         codex_home: home,
                                         log_sink: null_sink)
        stub_process_runner(silent_timeout_result, emit_line: turn_completed_line)

        result = invocation.run

        expect(result).to be_success
        expect(result.timed_out).to be false
        expect(result.exit_status).to eq(0)
        expect(result.outcome).to eq("success")
      end
    end

    it "still surfaces a silent timeout when no provider result was received" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "x", api_key: "sk-test",
                                         codex_home: home,
                                         log_sink: null_sink)
        stub_process_runner(silent_timeout_result)

        result = invocation.run

        expect(result).not_to be_success
        expect(result.timed_out).to be true
        expect(result.exit_status).to be_nil
      end
    end

    it "still surfaces a timeout when the provider result was an error" do
      turn_failed_line = { type: "turn.failed", error: "context window exceeded" }.to_json
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "x", api_key: "sk-test",
                                         codex_home: home,
                                         log_sink: null_sink)
        stub_process_runner(silent_timeout_result, emit_line: turn_failed_line)

        result = invocation.run

        expect(result).not_to be_success
        expect(result.timed_out).to be true
        expect(result.is_error).to be true
      end
    end
  end

  describe "process_event usage limits" do
    it "captures Codex turn failures with exhausted model quota as a distinct outcome" do
      events = []
      invocation = described_class.new(
        "/tmp/wkt",
        prompt: "P",
        api_key: "sk-test",
        model: "gpt-5.5"
      )
      event = {
        type: "turn.failed",
        error: "Your weekly usage limit has been exhausted for this model. Check billing to continue."
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to include(
        is_error: true,
        outcome: "provider_usage_limit",
        final_text: a_string_including("model gpt-5.5", "weekly usage limit")
      )
      expect(events).to include([
        a_string_including("[codex error]", "model gpt-5.5", "weekly usage limit"),
        { kind: "system" }
      ])
    end

    it "keeps ordinary Codex turn failures generic" do
      events = []
      invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", model: "gpt-5.5")
      event = { type: "turn.failed", error: "temporary upstream failure" }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to include(is_error: true, outcome: "turn_failed", final_text: "temporary upstream failure")
      expect(events).to include([ "[codex error] temporary upstream failure", { kind: "system" } ])
    end
  end

  describe "process_item_event structured tool wiring" do
    def invocation_with_sink
      events = []
      inv = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test")
      [ inv, events, ->(line, **kwargs) { events << [ line, kwargs ] } ]
    end

    it "emits tool_call with name, input, and id for mcp_tool_call started event" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.started",
        "id" => "call-xyz",
        "item" => { "type" => "mcp_tool_call", "server" => "syrus", "tool" => "propose_job", "arguments" => { "title" => "T" } }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.size).to eq(1)
      expect(events.first.last).to include(
        kind: "tool_call",
        tool_name: "syrus.propose_job",
        tool_input: { "title" => "T" },
        tool_use_id: "call-xyz"
      )
    end

    it "emits tool_result with content and tool_use_id for mcp_tool_call completed with result" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "id" => "call-xyz",
        "item" => { "type" => "mcp_tool_call", "server" => "syrus", "tool" => "propose_job", "result" => [ { "type" => "text", "text" => "Job drafted" } ] }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.size).to eq(1)
      expect(events.first.last).to include(
        kind: "tool_result",
        tool_name: "syrus.propose_job",
        tool_result_content: [ { "type" => "text", "text" => "Job drafted" } ],
        tool_result_error: false,
        tool_use_id: "call-xyz"
      )
    end

    it "emits tool_result with is_error true for mcp_tool_call completed with error" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "id" => "call-err",
        "item" => { "type" => "mcp_tool_call", "server" => "syrus", "tool" => "propose_job", "error" => { "message" => "not found" } }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_result",
        tool_result_content: "not found",
        tool_result_error: true,
        tool_use_id: "call-err"
      )
    end

    it "emits tool_result for mcp_tool_call completed with a string error" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "id" => "call-string-err",
        "item" => {
          "type" => "mcp_tool_call",
          "server" => "syrus",
          "tool" => "read_live_state",
          "error" => "sidecar unavailable"
        }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first).to eq([
        "[codex mcp] syrus.read_live_state completed: sidecar unavailable",
        {
          kind: "tool_result",
          tool_name: "syrus.read_live_state",
          tool_result_content: "sidecar unavailable",
          tool_result_error: true,
          tool_use_id: "call-string-err"
        }
      ])
    end

    it "emits tool_result for apply_patch completed with boolean error and preserved failure output" do
      inv, events, sink = invocation_with_sink
      failure_text = "apply_patch verification failed: Failed to find expected lines in app/models/run.rb"
      event = {
        "type" => "item.completed",
        "id" => "patch-err",
        "item" => {
          "type" => "mcp_tool_call",
          "server" => "functions",
          "tool" => "apply_patch",
          "error" => true,
          "output" => failure_text
        }
      }

      expect { inv.send(:process_item_event, event, sink) }.not_to raise_error

      expect(events.first).to eq([
        "[codex mcp] functions.apply_patch completed: #{failure_text}",
        {
          kind: "tool_result",
          tool_name: "functions.apply_patch",
          tool_result_content: failure_text,
          tool_result_error: true,
          tool_use_id: "patch-err"
        }
      ])
    end

    it "emits tool_call with name bash and input command for command_execution started" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.started",
        "id" => "cmd-1",
        "item" => { "type" => "command_execution", "command" => "ls -la" }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_call",
        tool_name: "bash",
        tool_input: { "command" => "ls -la" },
        tool_use_id: "cmd-1"
      )
    end

    it "emits tool_result for command_execution completed with output" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "id" => "cmd-1",
        "item" => { "type" => "command_execution", "command" => "ls -la", "output" => "total 8\ndrwxr-xr-x  2 root root 4096 ..." }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_result",
        tool_name: "bash",
        tool_result_content: "total 8\ndrwxr-xr-x  2 root root 4096 ...",
        tool_result_error: false,
        tool_use_id: "cmd-1"
      )
    end

    it "emits tool_result with is_error true for command_execution completed with error" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "id" => "cmd-2",
        "item" => { "type" => "command_execution", "command" => "rm /read-only", "error" => "Permission denied" }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_result",
        tool_result_error: true,
        tool_use_id: "cmd-2"
      )
    end

    it "falls back to item id when event id is absent" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.started",
        "item" => { "type" => "mcp_tool_call", "id" => "item-fallback", "server" => "s", "tool" => "t" }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last[:tool_use_id]).to eq("item-fallback")
    end

    it "does not log nameless MCP or command tool rows" do
      inv, events, sink = invocation_with_sink

      inv.send(:process_item_event, { "type" => "item.started", "item" => { "type" => "mcp_tool_call" } }, sink)
      inv.send(:process_item_event, { "type" => "item.started", "item" => { "type" => "command_execution" } }, sink)

      expect(events).to be_empty
    end
  end
end
