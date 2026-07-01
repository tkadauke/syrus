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
                                   resume_transcript_jsonl: "jsonl").run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        api_key: "sk-test",
        codex_home: "/tmp/codex-home",
        resume_session_id: "abc",
        resume_transcript_jsonl: "jsonl",
        model: "gpt-5.5"
      )
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    def capture_popen(invocation, lines: nil, exitstatus: 0)
      captured = { env: nil, cmd: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *args, **opts, &blk|
        captured[:env] = env
        captured[:cmd] = args
        captured[:opts] = opts
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
        blk.call($stdin, rd, fake_wait)
        rd.close
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
        expect(captured[:cmd]).to include("--dangerously-bypass-approvals-and-sandbox", "--json", "019e-test", "P")
        expect(captured[:cmd]).not_to include("--cd")
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
              args: [],
              env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "essential" },
              required: true
            },
            "syrus-chat-deferred-sidecar" => {
              command: "/app/bin/syrus-chat-deferred-sidecar",
              args: [],
              env: { "SYRUS_CHAT_MCP_TOOL_TIER" => "deferred" },
              required: false
            }
          }
        )

        capture_popen(invocation)

        config = File.read(File.join(home, "config.toml"))
        expect(config).to include("[mcp_servers.syrus-chat-sidecar]")
        expect(config).to include('command = "/app/bin/syrus-chat-sidecar"')
        expect(config).to include("required = true")
        expect(config).to include("[mcp_servers.syrus-chat-sidecar.env]")
        expect(config).to include('SYRUS_CHAT_MCP_TOOL_TIER = "essential"')
        expect(config).to include("[mcp_servers.syrus-chat-deferred-sidecar]")
        expect(config).to include('command = "/app/bin/syrus-chat-deferred-sidecar"')
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
  end

  describe "Codex item event logging" do
    it "passes structured metadata for MCP tool calls and results" do
      invocation = described_class.new("/tmp/wkt", prompt: "P")
      events = []
      log_sink = ->(chunk, **kwargs) { events << [ chunk, kwargs ] }

      invocation.send(:process_event, {
        type: "item.started",
        item: {
          type: "mcp_tool_call",
          server: "syrus-chat-sidecar",
          tool: "repo_info",
          arguments: { "repository_id" => 12 },
          call_id: "call_1"
        }
      }.to_json, log_sink)
      invocation.send(:process_event, {
        type: "item.completed",
        item: {
          type: "mcp_tool_call",
          server: "syrus-chat-sidecar",
          tool: "repo_info",
          result: { "slug" => "acme/widgets" },
          call_id: "call_1"
        }
      }.to_json, log_sink)

      expect(events).to contain_exactly(
        [
          "[codex mcp] syrus-chat-sidecar.repo_info started",
          include(
            kind: "tool_call",
            tool_name: "mcp__syrus-chat-sidecar__repo_info",
            tool_input: { "repository_id" => 12, "status" => "started" },
            tool_use_id: "call_1"
          )
        ],
        [
          "[codex mcp] syrus-chat-sidecar.repo_info completed",
          include(
            kind: "tool_result",
            tool_name: "mcp__syrus-chat-sidecar__repo_info",
            tool_result_content: { "slug" => "acme/widgets" },
            tool_result_error: false,
            tool_use_id: "call_1"
          )
        ]
      )
    end

    it "passes structured metadata for command executions" do
      invocation = described_class.new("/tmp/wkt", prompt: "P")
      events = []
      log_sink = ->(chunk, **kwargs) { events << [ chunk, kwargs ] }

      invocation.send(:process_event, {
        type: "item.started",
        item: {
          type: "command_execution",
          command: "bin/rspec spec/services/codex_invocation_spec.rb",
          id: "cmd_1"
        }
      }.to_json, log_sink)

      expect(events).to eq([
        [
          "[codex command] bin/rspec spec/services/codex_invocation_spec.rb started",
          {
            kind: "tool_call",
            tool_name: "Command",
            tool_input: {
              "command" => "bin/rspec spec/services/codex_invocation_spec.rb",
              "status" => "started"
            },
            tool_use_id: "cmd_1"
          }
        ]
      ])
    end

    it "does not log nameless MCP or command tool rows" do
      invocation = described_class.new("/tmp/wkt", prompt: "P")
      events = []
      log_sink = ->(chunk, **kwargs) { events << [ chunk, kwargs ] }

      invocation.send(:process_event, { type: "item.started", item: { type: "mcp_tool_call" } }.to_json, log_sink)
      invocation.send(:process_event, { type: "item.started", item: { type: "command_execution" } }.to_json, log_sink)

      expect(events).to be_empty
    end
  end
end
