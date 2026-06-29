require "rails_helper"
require "tmpdir"

RSpec.describe OpenCodeInvocation do
  def backend(**overrides)
    described_class::BackendConfig.new(**{
      backend: "openai_api",
      model: "gpt-4.1",
      api_key: "sk-test",
      endpoint_url: nil
    }.merge(overrides))
  end

  def result_fixture(**overrides)
    defaults = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "stop",
      final_text: "done",
      session_id: "ses_test"
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

      result = described_class.new(
        "/tmp/wkt",
        prompt: "do it",
        backend_config: backend,
        runner: runner,
        opencode_home: "/tmp/opencode-home",
        mcp_server: { command: "sidecar", args: [] },
        resume_session_id: "ses_old",
        resume_transcript_jsonl: "{\"type\":\"step_start\"}\n"
      ).run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        backend_config: backend,
        opencode_home: "/tmp/opencode-home",
        resume_session_id: "ses_old",
        resume_transcript_jsonl: "{\"type\":\"step_start\"}\n"
      )
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    def capture_popen(invocation, lines: nil)
      captured = { env: nil, cmd: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *args, **opts, &blk|
        captured[:env] = env
        captured[:cmd] = args
        captured[:opts] = opts
        rd, wr = IO.pipe
        Array(lines || [
          { type: "step_start", sessionID: "ses_test", part: { type: "step-start" } },
          { type: "text", sessionID: "ses_test", part: { type: "text", text: "done" } },
          { type: "step_finish", sessionID: "ses_test", part: { type: "step-finish", reason: "stop", cost: 0.01, tokens: { input: 10, output: 2, cache: { read: 3, write: 4 } } } }
        ]).each { |event| wr.write(event.to_json + "\n") }
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      result = invocation.run
      [ captured, result ]
    end

    it "runs opencode in JSON mode with an isolated per-run config" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", backend_config: backend, opencode_home: home)

        captured, result = capture_popen(invocation)

        expect(captured[:cmd]).to include(
          "opencode", "run",
          "--format", "json",
          "--dir", "/tmp/wkt",
          "--model", "openai/gpt-4.1",
          "--dangerously-skip-permissions",
          "P"
        )
        expect(captured[:env]["HOME"]).to eq(home)
        expect(captured[:env]["OPENCODE_CONFIG"]).to eq(File.join(home, "opencode.json"))
        expect(captured[:env]["SYRUS_OPENCODE_API_KEY"]).to eq("sk-test")
        expect(captured[:env]["BUNDLE_PATH"]).to eq("/tmp/wkt/.syrus/deps/bundle")
        expect(captured[:opts][:unsetenv_others]).to be true
        expect(result).to be_success
      end
    end

    it "writes OpenAI provider config using env-substituted API key" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", backend_config: backend, opencode_home: home)

        capture_popen(invocation)

        config = JSON.parse(File.read(File.join(home, "opencode.json")))
        expect(config).to include(
          "$schema" => "https://opencode.ai/config.json",
          "model" => "openai/gpt-4.1",
          "enabled_providers" => [ "openai" ]
        )
        expect(config.dig("provider", "openai", "options", "apiKey")).to eq("{env:SYRUS_OPENCODE_API_KEY}")
        expect(config.dig("provider", "openai", "models", "gpt-4.1", "name")).to eq("gpt-4.1")
      end
    end

    it "writes Azure OpenAI as an OpenAI-compatible provider with baseURL" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend(backend: "azure_openai", endpoint_url: "https://example.openai.azure.com/openai/v1"),
          opencode_home: home
        )

        capture_popen(invocation)

        config = JSON.parse(File.read(File.join(home, "opencode.json")))
        expect(config["model"]).to eq("syrus-azure-openai/gpt-4.1")
        provider = config.dig("provider", "syrus-azure-openai")
        expect(provider).to include(
          "npm" => "@ai-sdk/openai-compatible",
          "name" => "Syrus Azure OpenAI"
        )
        expect(provider.dig("options", "baseURL")).to eq("https://example.openai.azure.com/openai/v1")
        expect(provider.dig("options", "apiKey")).to eq("{env:SYRUS_OPENCODE_API_KEY}")
      end
    end

    it "writes Ollama as a local OpenAI-compatible provider without API key" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend(backend: "ollama", model: "llama3.2:70b", api_key: nil, endpoint_url: "http://localhost:11434/v1"),
          opencode_home: home
        )

        capture_popen(invocation)

        config = JSON.parse(File.read(File.join(home, "opencode.json")))
        expect(config["model"]).to eq("ollama/llama3.2:70b")
        expect(config.dig("provider", "ollama", "options")).to eq("baseURL" => "http://localhost:11434/v1")
      end
    end

    it "wires the Syrus MCP sidecar using OpenCode's mcp.local config" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend,
          opencode_home: home,
          mcp_server: {
            command: "/app/bin/syrus-mcp-sidecar",
            args: [ "--run-id", "12" ],
            env: { "RAILS_ENV" => "test", "RAILS_MASTER_KEY" => "secret" }
          }
        )

        captured, = capture_popen(invocation)

        config = JSON.parse(File.read(File.join(home, "opencode.json")))
        server = config.dig("mcp", "syrus-mcp-sidecar")
        expect(server).to include(
          "type" => "local",
          "command" => [ "/app/bin/syrus-mcp-sidecar", "--run-id", "12" ],
          "enabled" => true,
          "timeout" => 60_000
        )
        expect(server["environment"]).to include("RAILS_MASTER_KEY" => "secret")
        expect(captured[:cmd].join(" ")).not_to include("RAILS_MASTER_KEY")
      end
    end

    it "runs opencode run --session when resume_session_id is set and restores captured JSONL" do
      Dir.mktmpdir do |home|
        jsonl = { type: "step_start", sessionID: "ses_old" }.to_json + "\n"
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend,
          opencode_home: home,
          resume_session_id: "ses_old",
          resume_transcript_jsonl: jsonl
        )

        captured, = capture_popen(invocation)

        expect(captured[:cmd]).to include("--session", "ses_old")
        expect(File.read(File.join(home, "syrus-transcripts", "ses_old.jsonl"))).to include("ses_old")
      end
    end

    it "parses JSONL events into the common AgentInvocation::Result shape and logs rows by kind" do
      logs = []
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend,
          opencode_home: home,
          log_sink: ->(message, **metadata) { logs << [ message, metadata ] }
        )

        _, result = capture_popen(invocation, lines: [
          { type: "step_start", sessionID: "ses_test", part: { type: "step-start" } },
          { type: "tool_use", sessionID: "ses_test", part: { type: "tool", callID: "call_1", tool: "bash", state: { status: "completed", input: { command: "echo hi" }, output: "hi\n" } } },
          { type: "text", sessionID: "ses_test", part: { type: "text", text: "done" } },
          { type: "step_finish", sessionID: "ses_test", part: { type: "step-finish", reason: "stop", cost: 0.01, tokens: { input: 10, output: 2, cache: { read: 3, write: 4 } } } }
        ])

        expect(result.session_id).to eq("ses_test")
        expect(result.turns).to eq(1)
        expect(result.outcome).to eq("stop")
        expect(result.final_text).to eq("done")
        expect(result.cost_usd).to eq(0.01)
        expect(result.input_tokens).to eq(10)
        expect(result.output_tokens).to eq(2)
        expect(result.cache_read_input_tokens).to eq(3)
        expect(result.cache_creation_input_tokens).to eq(4)
        expect(result.transcript_jsonl).to include("\"type\":\"text\"")
        expect(File.read(result.transcript_path)).to include("ses_test")
        expect(logs.map { |_, metadata| metadata[:kind] }).to include("tool_call", "tool_result", "assistant_text", "system")
      end
    end

    it "marks error events as failed agent outcomes" do
      logs = []
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          backend_config: backend,
          opencode_home: home,
          log_sink: ->(message, **metadata) { logs << [ message, metadata ] }
        )

        _, result = capture_popen(invocation, lines: [
          { type: "step_start", sessionID: "ses_test", part: { type: "step-start" } },
          { type: "error", sessionID: "ses_test", error: { name: "APIError", data: { message: "Rate limit exceeded" } } }
        ])

        expect(result.session_id).to eq("ses_test")
        expect(result.is_error).to be true
        expect(result.outcome).to eq("error")
        expect(result.final_text).to eq("Rate limit exceeded")
        expect(logs.last).to eq([ "[opencode error] Rate limit exceeded", { kind: "system" } ])
      end
    end
  end
end
