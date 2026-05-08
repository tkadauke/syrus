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
        resume_transcript_jsonl: "jsonl"
      )
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    def capture_popen(invocation)
      captured = { env: nil, cmd: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *args, **opts, &blk|
        captured[:env] = env
        captured[:cmd] = args
        captured[:opts] = opts
        rd, wr = IO.pipe
        wr.write({ type: "thread.started", thread_id: "019e-test" }.to_json + "\n")
        wr.write({ type: "item.completed", item: { type: "agent_message", text: "done" } }.to_json + "\n")
        wr.write({ type: "turn.completed", usage: { input_tokens: 1, output_tokens: 2, reasoning_output_tokens: 0 } }.to_json + "\n")
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
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
      end
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
        expect(config).to include('[mcp_servers.syrus-mcp-sidecar]')
        expect(config).to include('command = "/app/bin/syrus-mcp-sidecar"')
        expect(config).to include('args = ["--run-id", "12"]')
        expect(config).to include("required = true")
        expect(config).to include('[mcp_servers.syrus-mcp-sidecar.env]')
        expect(config).to include('RAILS_ENV = "test"')
        expect(config).to include('RAILS_MASTER_KEY = "secret"')
        expect(captured[:cmd].join(" ")).not_to include("RAILS_MASTER_KEY")
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
        expect(result).to be_success
      end
    end
  end
end
