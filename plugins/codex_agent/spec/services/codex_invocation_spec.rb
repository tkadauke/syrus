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
                                   effort_level: "high",
                                   startup_timing: startup_timing).run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        api_key: "sk-test",
        codex_home: "/tmp/codex-home",
        resume_session_id: "abc",
        resume_transcript_jsonl: "jsonl",
        model: "gpt-5.5",
        effort_level: "high",
        startup_timing: startup_timing
      )
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    # A rollout in Codex's own on-disk format -- the only shape Codex can
    # resume from. Specs that exercise resume need one present, because a
    # session with no resumable rollout now starts fresh instead.
    def write_native_rollout(home, session_id, dir: "2026/10/04", time: "2026-10-04T11-49-01")
      path = File.join(home, "sessions", dir, "rollout-#{time}-#{session_id}.jsonl")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, { type: "session_meta", payload: { id: session_id } }.to_json + "\n")
      path
    end

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

    it "writes model_reasoning_effort to config.toml when effort_level is given" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home, effort_level: "high")

        capture_popen(invocation)

        expect(File.read(File.join(home, "config.toml"))).to include('model_reasoning_effort = "high"')
      end
    end

    it "omits model_reasoning_effort from config.toml by default, preserving current behavior" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)

        capture_popen(invocation)

        expect(File.read(File.join(home, "config.toml"))).not_to include("model_reasoning_effort")
      end
    end

    it "omits model_reasoning_effort from config.toml when effort_level is 'none'" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home, effort_level: "none")

        capture_popen(invocation)

        expect(File.read(File.join(home, "config.toml"))).not_to include("model_reasoning_effort")
      end
    end

    it "runs codex exec resume when resume_session_id is set" do
      Dir.mktmpdir do |home|
        write_native_rollout(home, "019e-test")
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

    it "restores a captured rollout JSONL to Codex's canonical filename before resume" do
      Dir.mktmpdir do |home|
        jsonl = { type: "session_meta", payload: { id: "019e-test" } }.to_json + "\n"
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test",
                                         resume_transcript_jsonl: jsonl)
        _, result = capture_popen(invocation)

        restored = Dir.glob(File.join(home, "sessions", "**", "*019e-test.jsonl"))
        expect(restored.size).to eq(1)
        expect(File.basename(restored.first)).to match(/\Arollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-019e-test\.jsonl\z/)
        expect(File.read(restored.first)).to eq(jsonl)
        expect(result.transcript_path).to eq(restored.first)
      end
    end

    it "replaces an unreadable rollout with supplied JSONL that is in Codex's on-disk format" do
      Dir.mktmpdir do |home|
        stale_jsonl = { type: "stale", payload: { token: "old-turn-token" } }.to_json + "\n"
        sanitized_jsonl = { type: "session_meta", payload: { id: "019e-test", source: "rehydrated" } }.to_json + "\n"
        stale_dir = File.join(home, "sessions", "2026", "09", "01")
        FileUtils.mkdir_p(stale_dir)
        stale_path = File.join(stale_dir, "rollout-2026-09-01T00-00-00-019e-test.jsonl")
        File.write(stale_path, stale_jsonl)
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test",
                                         resume_transcript_jsonl: sanitized_jsonl)

        _, result = capture_popen(invocation)

        expect(File.read(stale_path)).to eq(sanitized_jsonl)
        expect(result.transcript_path).to eq(stale_path)
      end
    end

    it "copies an old non-canonical restored rollout into a canonical path" do
      Dir.mktmpdir do |home|
        jsonl = { type: "session_meta", payload: { id: "019e-test" } }.to_json + "\n"
        stale_dir = File.join(home, "sessions", "2026", "09", "01")
        FileUtils.mkdir_p(stale_dir)
        File.write(File.join(stale_dir, "rollout-restored-019e-test.jsonl"), jsonl)
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test")

        captured, result = capture_popen(invocation)

        canonical = Dir.glob(File.join(home, "sessions", "**", "rollout-[0-9]*-019e-test.jsonl"))
        expect(canonical.size).to eq(1)
        expect(File.read(canonical.first)).to eq(jsonl)
        expect(result.transcript_path).to eq(canonical.first)
        expect(captured[:cmd][0, 3]).to eq(%w[codex exec resume])
      end
    end

    it "starts fresh instead of resuming when a canonical rollout path cannot be derived" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "../bad-session",
                                         resume_transcript_jsonl: "{}\n",
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        captured, = capture_popen(invocation)

        expect(captured[:cmd][0, 2]).to eq(%w[codex exec])
        expect(captured[:cmd]).not_to include("resume")
        expect(captured[:cmd]).to include("--cd", "/tmp/wkt")
        expect(events).to include([
          "[codex resume] could not derive a canonical rollout path for session ../bad-session; starting a fresh Codex session",
          { kind: "system" }
        ])
      end
    end

    it "starts a fresh session when a resumed Codex session has no rollout to restore" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-missing",
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        captured, = capture_popen(invocation)

        expect(captured[:cmd]).not_to include("resume")
        expect(events).to include([
          "[codex resume] no resumable rollout stored for session 019e-missing; starting a fresh Codex session",
          { kind: "system" }
        ])
      end
    end

    # Regression: the rollout Codex writes uses its on-disk vocabulary
    # (session_meta / response_item / event_msg). Overwriting it with the
    # transcript synthesized from ChatMessage rows -- which uses Codex's stdout
    # *event* vocabulary (thread.started / item.*) -- left Codex unable to find
    # session metadata. Codex reported the rollout as empty and failed the
    # turn, and since the next turn overwrote it again the chat never
    # recovered.
    it "never overwrites Codex's own rollout with a synthesized stdout-event transcript" do
      Dir.mktmpdir do |home|
        native = [
          { type: "session_meta", payload: { id: "019e-test", cwd: "/w" } }.to_json,
          { type: "response_item", payload: { content: [ { text: "prior turn" } ] } }.to_json
        ].join("\n") + "\n"
        synthesized = [
          { type: "thread.started", thread_id: "019e-test" }.to_json,
          { type: "item.completed", item: { text: "prior turn" } }.to_json,
          { type: "turn.completed" }.to_json
        ].join("\n") + "\n"
        dir = File.join(home, "sessions", "2026", "10", "04")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "rollout-2026-10-04T11-49-01-019e-test.jsonl")
        File.write(path, native)

        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test",
                                         resume_transcript_jsonl: synthesized)

        captured, result = capture_popen(invocation)

        expect(File.read(path)).to eq(native)
        expect(result.transcript_path).to eq(path)
        expect(captured[:cmd][0, 3]).to eq(%w[codex exec resume])
      end
    end

    it "redacts MCP invocation tokens from Codex's rollout without changing its format" do
      Dir.mktmpdir do |home|
        leaked = [
          { type: "session_meta", payload: { id: "019e-test" } }.to_json,
          { type: "event_msg",
            payload: { item: { stdout: "SYRUS_MCP_PROXY_INVOCATION_CONTEXT=tok-secret-123 rest" } } }.to_json
        ].join("\n") + "\n"
        dir = File.join(home, "sessions", "2026", "10", "04")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "rollout-2026-10-04T11-49-01-019e-test.jsonl")
        File.write(path, leaked)

        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home, resume_session_id: "019e-test")

        capture_popen(invocation)

        written = File.read(path)
        expect(written).not_to include("tok-secret-123")
        expect(JSON.parse(written.lines.first)["type"]).to eq("session_meta")
        expect(JSON.parse(written.lines.last).dig("payload", "item", "stdout"))
          .to eq("SYRUS_MCP_PROXY_INVOCATION_CONTEXT=[redacted] rest")
      end
    end

    # Auto-repair for chats already bricked by the overwrite above: their
    # stored rollout is the synthesized format, which Codex rejects. Rather
    # than failing every turn forever, start a fresh Codex session.
    it "starts a fresh session when the stored rollout is not in Codex's resumable format" do
      Dir.mktmpdir do |home|
        events = []
        synthesized = { type: "thread.started", thread_id: "019e-test" }.to_json + "\n"
        dir = File.join(home, "sessions", "2026", "10", "04")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "rollout-2026-10-04T11-49-01-019e-test.jsonl"), synthesized)

        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-test",
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        captured, = capture_popen(invocation)

        expect(captured[:cmd][0, 2]).to eq(%w[codex exec])
        expect(captured[:cmd]).not_to include("resume")
        expect(events).to include([
          "[codex resume] stored rollout for session 019e-test is not in Codex's resumable " \
          "format; starting a fresh Codex session",
          { kind: "system" }
        ])
      end
    end

    it "logs when a Codex resume turn fails" do
      Dir.mktmpdir do |home|
        events = []
        write_native_rollout(home, "019e-gone")
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test",
                                         codex_home: home,
                                         resume_session_id: "019e-gone",
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

    it "writes a Codex config.toml for the direct Rails MCP sidecar with boot env" do
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
        expect(config).to include("tool_timeout_sec = 120")
        expect(config).to include('[mcp_servers.syrus-mcp-sidecar.env]')
        expect(config).to include('RAILS_ENV = "test"')
        expect(config).to include('RAILS_MASTER_KEY = "secret"')
        expect(captured[:cmd].join(" ")).not_to include("RAILS_MASTER_KEY")
      end
    end

    it "keeps proxy MCP config secret-free" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          api_key: "sk-test",
          codex_home: home,
          mcp_server: {
            command: "/app/bin/syrus-mcp-proxy",
            args: [],
            env: { "PATH" => "/usr/bin", "RAILS_MASTER_KEY" => "secret" }
          }
        )
        capture_popen(invocation)

        config = File.read(File.join(home, "config.toml"))
        expect(config).to include('PATH = "/usr/bin"')
        expect(config).not_to include("RAILS_MASTER_KEY")
        expect(config).not_to include("secret")
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
        mcp_event = events.find { |event| event.include?('stage="mcp_startup"') }
        expect(mcp_event).to include('status="connected"', 'servers="syrus-chat-sidecar"')
      end
    end

    it "does not record MCP startup success from output that arrives before any MCP lifecycle event" do
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

        # thread.started arrives first and is unrelated to MCP; the turn
        # completes without ever exercising the MCP server (no
        # mcp_tool_call item anywhere in the stream).
        capture_popen(invocation, lines: [
          { type: "thread.started", thread_id: "019e-test" },
          { type: "item.completed", item: { type: "agent_message", text: "done" } },
          { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 2 } }
        ])

        first_agent_event = events.find { |event| event.include?('stage="first_agent_event"') }
        mcp_event = events.find { |event| event.include?('stage="mcp_startup"') }

        expect(first_agent_event).to be_present
        expect(mcp_event).to be_present
        expect(mcp_event).not_to include('status="connected"')
        expect(mcp_event).to include('status="pending"', 'servers="syrus-chat-sidecar"')
      end
    end

    it "records MCP startup as failed when the turn errors before any MCP server is ever reached" do
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
          { type: "turn.failed", error: "mcp server failed to start" }
        ])

        mcp_event = events.find { |event| event.include?('stage="mcp_startup"') }
        expect(mcp_event).to include('status="failed"', 'servers="syrus-chat-sidecar"')
      end
    end

    it "records MCP startup as missing when no MCP servers are configured" do
      Dir.mktmpdir do |home|
        events = []
        timing = described_class::StartupTiming.new(source: "spec", sink: ->(event) { events << event })
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home, startup_timing: timing)

        capture_popen(invocation)

        mcp_event = events.find { |event| event.include?('stage="mcp_startup"') }
        expect(mcp_event).to include('status="missing"')
      end
    end

    it "reports chat_startup.* phases for filesystem-bound stages when the timer is chat-scoped" do
      Dir.mktmpdir do |home|
        Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
        allow(PerformanceLogging).to receive(:slow_phase_threshold_ms).and_return(0.0)
        PerformanceLogging::Store.clear!
        chat_session = ChatSession.create!(user: Factories.user)
        Thread.current[:syrus_current_chat_session] = chat_session

        timing = described_class::StartupTiming.new(source: "codex_chat")
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home, startup_timing: timing)
        capture_popen(invocation, lines: [
          { type: "thread.started", thread_id: "019e-test" },
          { type: "turn.completed", usage: {} }
        ])

        phases = PerformanceLogging::Store.recent.map { |event| event["phase"] }
        expect(phases).to include(
          "chat_startup.codex_home_prepare", "chat_startup.config_write", "chat_startup.transcript_restore"
        )
        # process_spawn shows up exactly once -- from ProcessRunner, which
        # instruments spawn latency uniformly for both providers -- not
        # doubled by StartupTiming's own "process_spawn" stage, which is
        # deliberately excluded from the bridge (see CHAT_STARTUP_STAGES).
        expect(phases.count("chat_startup.process_spawn")).to eq(1)
        # Provider round-trip stages measure waiting on the model, not local
        # storage, so they never get bridged at all.
        expect(phases).not_to include("chat_startup.first_agent_event", "chat_startup.mcp_startup")
        event = PerformanceLogging::Store.recent.find { |e| e["phase"] == "chat_startup.config_write" }
        expect(event["metadata"]).to include("provider" => "codex", "chat_session_id" => chat_session.id.to_s)
      ensure
        Thread.current[:syrus_current_chat_session] = nil
        PerformanceLogging::Store.clear!
      end
    end

    it "does not report chat_startup.* phases for the default workflow-scoped timer" do
      Dir.mktmpdir do |home|
        Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
        allow(PerformanceLogging).to receive(:slow_phase_threshold_ms).and_return(0.0)
        PerformanceLogging::Store.clear!

        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home)
        capture_popen(invocation, lines: [
          { type: "thread.started", thread_id: "019e-test" },
          { type: "turn.completed", usage: {} }
        ])

        expect(PerformanceLogging::Store.recent).to be_empty
      ensure
        PerformanceLogging::Store.clear!
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

    it "surfaces primitive JSONL Codex output without crashing" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home,
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        _, result = capture_popen(invocation, lines: [ "true" ], exitstatus: 1)

        expect(result).not_to be_success
        expect(result.is_error).to be true
        expect(result.outcome).to eq("error")
        expect(result.final_text).to eq("true")
        expect(events).to include([ "true", {} ])
      end
    end

    it "redacts large Codex model metadata bodies from startup failures" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", codex_home: home,
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })
        model_catalog = {
          models: [
            {
              id: "gpt-5.5",
              supported_reasoning_effort: %w[low medium high max],
              prompt_template: "Do not store this provider prompt template." * 200
            }
          ]
        }.to_json
        stderr = "error: failed to refresh available models: unknown variant `max`; body: #{model_catalog}"

        _, result = capture_popen(invocation, lines: [ stderr ], exitstatus: 1)

        expected =
          "error: failed to refresh available models: unknown variant `max`; " \
          "body: [model metadata body omitted, #{model_catalog.bytesize} bytes]"
        expect(result).not_to be_success
        expect(result.final_text).to eq(expected)
        expect(events).to include([ expected, {} ])
        expect(result.final_text).not_to include("prompt_template")
        expect(events.join("\n")).not_to include("Do not store this provider prompt template")
      end
    end
  end

  describe "provider cleanup timeout handling" do
    let(:null_sink) { ->(_chunk, **) { } }

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

    it "attributes the spawned process to the current chat session so admin Processes can show the owner" do
      chat_session = ChatSession.create!(user: Factories.user)
      captured = {}
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured[:chat_session] = kwargs[:chat_session]
        captured[:agent] = kwargs[:agent]
        fake = double("ProcessRunner")
        allow(fake).to receive(:run).and_return(
          ProcessRunner::Result.new(
            exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false,
            operator_killed: false, aliveness_failed: false, duration_s: 1.0, spawned_process_id: nil
          )
        )
        fake
      end

      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "x", api_key: "sk-test",
                                         codex_home: home, log_sink: null_sink)
        begin
          Thread.current[:syrus_current_chat_session] = chat_session
          invocation.run
        ensure
          Thread.current[:syrus_current_chat_session] = nil
        end
      end

      expect(captured[:chat_session]).to eq(chat_session)
      expect(captured[:agent]).to eq(Agent.find_by!(resumable: chat_session))
    end

    it "attributes the spawned process to the current run's agent" do
      run = Factories.run
      captured = {}
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured[:run] = kwargs[:run]
        captured[:workflow] = kwargs[:workflow]
        captured[:agent] = kwargs[:agent]
        fake = double("ProcessRunner")
        allow(fake).to receive(:run).and_return(
          ProcessRunner::Result.new(
            exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false,
            operator_killed: false, aliveness_failed: false, duration_s: 1.0, spawned_process_id: nil
          )
        )
        fake
      end

      Dir.mktmpdir do |home|
        begin
          Thread.current[:syrus_current_run] = run
          described_class.new("/tmp/wkt", prompt: "x", api_key: "sk-test",
                              codex_home: home, log_sink: null_sink).run
        ensure
          Thread.current[:syrus_current_run] = nil
        end
      end

      expect(captured[:run]).to eq(run)
      expect(captured[:workflow]).to eq(run.workflow)
      expect(captured[:agent]).to eq(Agent.find_by!(resumable: run))
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

    it "captures Codex expired auth turn failures as a distinct outcome" do
      events = []
      invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test", model: "gpt-5.5")
      event = {
        type: "turn.failed",
        error: "Failed to refresh token: auth error code: token_expired"
      }.to_json

      update = invocation.send(:process_event, event, ->(line, **kwargs) { events << [ line, kwargs ] })

      expect(update).to include(
        is_error: true,
        outcome: "provider_auth_expired",
        final_text: "Failed to refresh token: auth error code: token_expired"
      )
      expect(events).to include([
        "[codex error] Failed to refresh token: auth error code: token_expired",
        { kind: "system" }
      ])
    end

    it "captures Codex websocket 401 errors as expired auth" do
      invocation = described_class.new("/tmp/wkt", prompt: "P", api_key: "sk-test")
      event = { type: "error", message: "websocket connection failed: HTTP 401 Unauthorized" }.to_json

      update = invocation.send(:process_event, event, ->(_line, **_) { })

      expect(update).to include(
        is_error: true,
        outcome: "provider_auth_expired",
        final_text: "websocket connection failed: HTTP 401 Unauthorized"
      )
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

    it "falls back to item call_id when event id and item id are absent" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "item" => {
          "type" => "mcp_tool_call",
          "call_id" => "call-test-plan",
          "server" => "syrus-mcp-sidecar",
          "tool_name" => "submit_test_plan",
          "result" => { "ok" => true }
        }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_result",
        tool_name: "syrus-mcp-sidecar.submit_test_plan",
        tool_use_id: "call-test-plan"
      )
    end

    it "uses dotted MCP item names without adding an empty server prefix" do
      inv, events, sink = invocation_with_sink
      event = {
        "type" => "item.completed",
        "item" => {
          "type" => "mcp_tool_call",
          "call_id" => "call-summary",
          "name" => "syrus-mcp-sidecar.submit_summary",
          "result" => { "ok" => true }
        }
      }

      inv.send(:process_item_event, event, sink)

      expect(events.first.last).to include(
        kind: "tool_result",
        tool_name: "syrus-mcp-sidecar.submit_summary",
        tool_use_id: "call-summary"
      )
    end

    it "does not log nameless MCP or command tool rows" do
      inv, events, sink = invocation_with_sink

      inv.send(:process_item_event, { "type" => "item.started", "item" => { "type" => "mcp_tool_call" } }, sink)
      inv.send(:process_item_event, { "type" => "item.started", "item" => { "type" => "command_execution" } }, sink)

      expect(events).to be_empty
    end
  end
end
