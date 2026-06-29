require "rails_helper"
require "tmpdir"

RSpec.describe GeminiInvocation do
  def result_fixture(**overrides)
    defaults = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: "gemini-session"
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
        api_key: "gemini-key",
        runner: runner,
        timeout: 60,
        model: "gemini-3-flash",
        mcp_config: "/tmp/mcp.json",
        resume_session_id: "resume-1",
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      ).run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        api_key: "gemini-key",
        timeout: 60,
        model: "gemini-3-flash",
        mcp_config: "/tmp/mcp.json",
        resume_session_id: "resume-1",
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      )
      expect(received[:stop_requested].call).to eq(false)
      expect(received[:process_started]).to respond_to(:call)
      expect(result).to be_success
    end
  end

  describe "default_runner" do
    def capture_popen(invocation, workspace:)
      captured = { env: nil, cmd: nil, opts: nil }
      allow(Open3).to receive(:popen2e) do |env, *args, **opts, &blk|
        captured[:env] = env
        captured[:cmd] = args
        captured[:opts] = opts
        rd, wr = IO.pipe
        wr.write({ type: "init", session_id: "gemini-123", model: "gemini-3-pro" }.to_json + "\n")
        wr.write({ type: "message", role: "assistant", content: "done" }.to_json + "\n")
        wr.write({
          type: "result",
          status: "success",
          usage: {
            input_tokens: 11,
            output_tokens: 7,
            cache_read_input_tokens: 3
          },
          cost_usd: 0.0042
        }.to_json + "\n")
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 0)
        blk.call($stdin, rd, fake_wait)
        rd.close
      end

      result = invocation.run
      [ captured, result ]
    end

    it "runs gemini headlessly with stream-json output, model, MCP config, and resume flags" do
      Dir.mktmpdir do |workspace|
        invocation = described_class.new(
          workspace,
          prompt: "P",
          api_key: "gemini-key",
          model: "gemini-3-flash",
          mcp_config: "/tmp/mcp.json",
          resume_session_id: "gemini-old"
        )

        captured, = capture_popen(invocation, workspace: workspace)

        expect(captured[:cmd]).to eq([
          "gemini",
          "-r", "gemini-old",
          "-p", "P",
          "--yolo",
          "--output-format", "stream-json",
          "--model", "gemini-3-flash",
          "--mcp-config", "/tmp/mcp.json"
        ])
        expect(captured[:opts][:unsetenv_others]).to be true
      end
    end

    it "injects GEMINI_API_KEY and trust while stripping worker Rails/Bundler env" do
      saved = ENV.to_h
      ENV["RAILS_MASTER_KEY"] = "do-not-leak"
      ENV["BUNDLE_GEMFILE"] = "/rails/Gemfile"
      ENV["PATH"] = "/usr/bin"

      Dir.mktmpdir do |workspace|
        invocation = described_class.new(workspace, prompt: "P", api_key: "gemini-key")
        captured, = capture_popen(invocation, workspace: workspace)

        expect(captured[:env]["GEMINI_API_KEY"]).to eq("gemini-key")
        expect(captured[:env]["GEMINI_CLI_TRUST_WORKSPACE"]).to eq("true")
        expect(captured[:env]["PATH"]).to eq("/usr/bin")
        expect(captured[:env]["BUNDLE_PATH"]).to eq(File.join(workspace, ".syrus", "deps", "bundle"))
        expect(captured[:env]).not_to have_key("RAILS_MASTER_KEY")
        expect(captured[:env]).not_to have_key("BUNDLE_GEMFILE")
      end
    ensure
      ENV.replace(saved)
    end

    it "returns session metadata, transcript JSONL/path, cost, and token usage" do
      Dir.mktmpdir do |workspace|
        invocation = described_class.new(workspace, prompt: "P", api_key: "gemini-key")
        _, result = capture_popen(invocation, workspace: workspace)

        expect(result.session_id).to eq("gemini-123")
        expect(result.transcript_jsonl).to include('"type":"init"')
        expect(result.transcript_path).to eq(File.join(workspace, ".syrus", "agent-transcripts", "gemini-gemini-123.jsonl"))
        expect(File.read(result.transcript_path)).to eq(result.transcript_jsonl)
        expect(result.cost_usd).to eq(0.0042)
        expect(result.input_tokens).to eq(11)
        expect(result.output_tokens).to eq(7)
        expect(result.cache_read_input_tokens).to eq(3)
        expect(result).to be_success
      end
    end
  end

  describe "stream-json event parsing" do
    let(:events) { [] }
    let(:invocation) { described_class.new("/tmp", prompt: "x", api_key: "key") }
    let(:log_sink) { ->(line, **kwargs) { events << [ line, kwargs ] } }

    it "captures session_id and MCP server status from init events" do
      update = invocation.send(
        :process_event,
        {
          type: "init",
          session_id: "gemini-123",
          mcp_servers: [ { name: "syrus-mcp-sidecar", status: "connected" } ]
        }.to_json,
        log_sink
      )

      expect(update).to eq(session_id: "gemini-123")
      expect(events).to contain_exactly(
        [
          "[mcp_servers] syrus-mcp-sidecar=connected",
          { kind: "system", mcp_servers: [ { "name" => "syrus-mcp-sidecar", "status" => "connected" } ] }
        ]
      )
    end

    it "maps assistant message chunks to assistant_text log rows" do
      update = invocation.send(:process_event, { type: "message", role: "assistant", content: "hello" }.to_json, log_sink)

      expect(update).to eq(final_text: "hello")
      expect(events).to eq([ [ "hello", { kind: "assistant_text" } ] ])
    end

    it "maps tool_use events to tool_call log rows" do
      invocation.send(:process_event, { type: "tool_use", tool_name: "run_shell_command", args: { command: "pwd" } }.to_json, log_sink)

      expect(events.last.first).to include("run_shell_command")
      expect(events.last.last).to include(
        kind: "tool_call",
        tool_name: "run_shell_command",
        tool_input: { "command" => "pwd" }
      )
    end

    it "maps tool_result events to tool_result log rows" do
      invocation.send(:process_event, { type: "tool_result", content: "ok", tool_use_id: "tool-1" }.to_json, log_sink)

      expect(events.last.last).to include(
        kind: "tool_result",
        tool_result_content: "ok",
        tool_result_error: false,
        tool_use_id: "tool-1"
      )
    end

    it "maps error events to system log rows and marks fatal errors" do
      update = invocation.send(:process_event, { type: "error", severity: "error", message: "auth failed" }.to_json, log_sink)

      expect(update).to eq(is_error: true, outcome: "error", final_text: "auth failed")
      expect(events.last).to eq([ "[gemini error] auth failed", { kind: "system" } ])
    end

    it "captures final status, text, cost, and token usage from result events" do
      update = invocation.send(
        :process_event,
        {
          type: "result",
          status: "success",
          response: "all done",
          usage: {
            input_tokens: 100,
            output_tokens: 20,
            cache_creation_input_tokens: 5,
            cache_read_input_tokens: 9
          },
          total_cost_usd: 0.01
        }.to_json,
        log_sink
      )

      expect(update).to include(
        turns: 1,
        is_error: false,
        outcome: "success",
        final_text: "all done",
        cost_usd: 0.01,
        input_tokens: 100,
        output_tokens: 20,
        cache_creation_input_tokens: 5,
        cache_read_input_tokens: 9
      )
      expect(events.last.first).to include("[gemini result] status=success")
    end

    it "accepts Google-style token usage field names" do
      update = invocation.send(
        :process_event,
        {
          type: "result",
          status: "success",
          usage: {
            promptTokenCount: 100,
            candidatesTokenCount: 20,
            cachedContentTokenCount: 9
          }
        }.to_json,
        log_sink
      )

      expect(update).to include(
        input_tokens: 100,
        output_tokens: 20,
        cache_read_input_tokens: 9
      )
    end

    it "passes non-JSON lines through verbatim" do
      update = invocation.send(:process_event, "not json", log_sink)

      expect(update).to be_nil
      expect(events).to eq([ [ "not json", {} ] ])
    end
  end
end
