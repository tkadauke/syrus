require "rails_helper"
require "tmpdir"

RSpec.describe AgyInvocation do
  def result_fixture(**overrides)
    defaults = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "done",
      session_id: "conversation-1"
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
                                   runner: runner,
                                   agy_home: "/tmp/agy-home",
                                   resume_session_id: "abc",
                                   model: "gemini-test",
                                   effort_level: "high").run

      expect(received).to include(
        workspace_path: "/tmp/wkt",
        prompt: "do it",
        agy_home: "/tmp/agy-home",
        resume_session_id: "abc",
        mcp_server: nil,
        model: "gemini-test",
        effort_level: "high",
        required_mcp_tools: []
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
          { event: "init", conversation_id: "conv-1", permission_mode: "always-proceed" },
          { event: "step_update", message: { content: "working" } },
          { event: "result", result: "done", num_turns: 3, usage: { input_tokens: 11, output_tokens: 7, thinking_tokens: 5, cache_tokens: 2, total_tokens: 25 } }
        ]).each do |line|
          wr.write(line.is_a?(String) ? line : line.to_json)
          wr.write("\n")
        end
        wr.close
        fake_wait = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(exitstatus), 0)
        stdin_reader = Thread.new { in_rd.read }
        blk.call(in_wr, rd, fake_wait)
        rd.close
        captured[:stdin] = stdin_reader.value
        in_rd.close
      end

      result = invocation.run
      [ captured, result ]
    end

    it "runs agy with stream-json, disabled prompts, and prompt NDJSON on stdin" do
      Dir.mktmpdir do |home|
        large_prompt = "P" * 140_000
        invocation = described_class.new("/tmp/wkt", prompt: large_prompt, agy_home: home)

        captured, = capture_popen(invocation)

        expect(captured[:cmd]).to eq([
          "agy",
          "--input-format", "stream-json",
          "--output-format", "stream-json",
          "--print=",
          "--dangerously-skip-permissions",
          "--disable-slash-commands",
          "--print-timeout", "90m"
        ])
        expect(captured[:cmd]).not_to include(large_prompt)
        expect(JSON.parse(captured[:stdin])).to eq(
          "event" => "user",
          "message" => { "content" => large_prompt }
        )
        expect(captured[:env]["HOME"]).to eq(home)
        expect(captured[:env]["AGY_HOME"]).to eq(home)
        expect(captured[:env]["ANTIGRAVITY_HOME"]).to eq(home)
      end
    end

    it "adds the conversation flag only when resuming" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home, resume_session_id: "conv-1")

        captured, = capture_popen(invocation)

        expect(captured[:cmd]).to include("--conversation", "conv-1")
        expect(captured[:cmd]).not_to include("P")
      end
    end

    it "passes model and effort settings from Syrus env vars" do
      old_model = ENV["SYRUS_AGY_MODEL"]
      old_effort = ENV["SYRUS_AGY_EFFORT"]
      ENV["SYRUS_AGY_MODEL"] = "gemini-test"
      ENV["SYRUS_AGY_EFFORT"] = "high"

      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home)

        captured, = capture_popen(invocation)

        expect(captured[:env]).to include(
          "SYRUS_AGY_MODEL" => "gemini-test",
          "SYRUS_AGY_EFFORT" => "high",
          "AGY_MODEL" => "gemini-test",
          "AGY_EFFORT" => "high"
        )
      end
    ensure
      ENV["SYRUS_AGY_MODEL"] = old_model
      ENV["SYRUS_AGY_EFFORT"] = old_effort
    end

    it "writes Antigravity MCP config in the isolated provider home" do
      Dir.mktmpdir do |home|
        invocation = described_class.new(
          "/tmp/wkt",
          prompt: "P",
          agy_home: home,
          mcp_server: {
            command: "/app/bin/syrus-mcp-sidecar",
            args: [ "--run-id", "123" ],
            env: { "RAILS_ENV" => "test", "SECRET" => nil }
          }
        )

        capture_popen(invocation)

        config = JSON.parse(File.read(File.join(home, ".gemini", "config", "mcp_config.json")))
        expect(config).to eq(
          "mcpServers" => {
            "syrus-mcp-sidecar" => {
              "command" => "/app/bin/syrus-mcp-sidecar",
              "args" => [ "--run-id", "123" ],
              "env" => { "RAILS_ENV" => "test" }
            }
          }
        )
      end
    end

    it "parses stream-json init, step_update, result, usage, and session fields" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home,
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        _, result = capture_popen(invocation)

        expect(result.session_id).to eq("conv-1")
        expect(result.turns).to eq(3)
        expect(result.outcome).to eq("success")
        expect(result.final_text).to eq("done")
        expect(result.input_tokens).to eq(11)
        expect(result.output_tokens).to eq(7)
        expect(result.cache_creation_input_tokens).to eq(5)
        expect(result.cache_read_input_tokens).to eq(2)
        expect(result).to be_success
        expect(events).to include([ "working", { kind: "assistant_text" } ])
        expect(events.map(&:first).join("\n")).to include("total_tokens=25")
      end
    end

    it "fails early when required MCP tools are missing from Agy init" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt",
                                         prompt: "P",
                                         agy_home: home,
                                         required_mcp_tools: %w[submit_summary])

        _, result = capture_popen(
          invocation,
          lines: [
            { event: "init", conversation_id: "conv-1", tools: [ "mcp(other/tool)" ] },
            { event: "result", result: "done", num_turns: 1 }
          ]
        )

        expect(result).not_to be_success
        expect(result.outcome).to eq("mcp_sidecar_failed")
      end
    end

    it "classifies usage-limit and auth failures from result events" do
      Dir.mktmpdir do |home|
        usage = described_class.new("/tmp/wkt", prompt: "P", agy_home: home)
        _, usage_result = capture_popen(
          usage,
          lines: [ { event: "result", is_error: true, result: "monthly usage limit exceeded" } ],
          exitstatus: 1
        )

        auth = described_class.new("/tmp/wkt", prompt: "P", agy_home: home)
        _, auth_result = capture_popen(
          auth,
          lines: [ { event: "error", message: "401 unauthorized" } ],
          exitstatus: 1
        )

        expect(usage_result.outcome).to eq(ProviderUsageLimit::OUTCOME)
        expect(auth_result.outcome).to eq(ProviderAuthFailure::OUTCOME)
      end
    end

    it "fails when no result event is emitted" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home)

        _, result = capture_popen(invocation, lines: [ { event: "init", conversation_id: "conv-1" } ])

        expect(result).not_to be_success
        expect(result.is_error).to be true
        expect(result.outcome).to eq("missing_result")
        expect(result.final_text).to include("Agy process ended without a result event")
      end
    end

    it "fails on nonzero exit without a result event" do
      Dir.mktmpdir do |home|
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home)

        _, result = capture_popen(invocation, lines: [], exitstatus: 2)

        expect(result).not_to be_success
        expect(result.outcome).to eq("process_failed")
        expect(result.final_text).to include("status 2")
      end
    end

    it "fails on timeout without a result event" do
      runner_result = ProcessRunner::Result.new(
        exit_status: nil,
        timed_out: true,
        stopped: false,
        silent_timed_out: false,
        operator_killed: false,
        aliveness_failed: false,
        duration_s: 5400.0,
        spawned_process_id: nil
      )
      allow(ProcessRunner).to receive(:new).and_return(double("ProcessRunner", run: runner_result))

      Dir.mktmpdir do |home|
        result = described_class.new("/tmp/wkt", prompt: "P", agy_home: home).run

        expect(result).not_to be_success
        expect(result.timed_out).to be true
        expect(result.outcome).to eq("timed_out")
        expect(result.final_text).to include("wall-clock timeout")
      end
    end

    it "surfaces malformed JSON lines as process failure details" do
      Dir.mktmpdir do |home|
        events = []
        invocation = described_class.new("/tmp/wkt", prompt: "P", agy_home: home,
                                         log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] })

        _, result = capture_popen(invocation, lines: [ "{not-json" ], exitstatus: 1)

        expect(result).not_to be_success
        expect(result.outcome).to eq("process_failed")
        expect(result.final_text).to eq("{not-json")
        expect(events).to include([ "{not-json", {} ])
      end
    end
  end
end
