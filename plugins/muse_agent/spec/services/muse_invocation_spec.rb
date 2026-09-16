require "rails_helper"
require "tmpdir"

RSpec.describe MuseInvocation do
  FIXTURE_PATH = File.expand_path("../fixtures/local_mode_echo.jsonl", __dir__)

  def process_result(exit_status: 0, timed_out: false, silent_timed_out: false, stopped: false)
    ProcessRunner::Result.new(
      exit_status: exit_status,
      timed_out: timed_out,
      stopped: stopped,
      silent_timed_out: silent_timed_out,
      operator_killed: false,
      aliveness_failed: false,
      duration_s: 0.1,
      spawned_process_id: nil
    )
  end

  def stub_process_runners(lines:, exit_status: 0, export_jsonl: nil, captured: [])
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:prompt_file_content] = File.read(kwargs[:command][kwargs[:command].index("--prompt-file") + 1]) if kwargs[:command][0, 2] == %w[muse exec]
      captured << kwargs
      instance_double(ProcessRunner).tap do |runner|
        allow(runner).to receive(:run) do
          if kwargs[:command][0, 2] == %w[muse exec]
            lines.each { |line| kwargs[:on_output_line].call(line) }
            process_result(exit_status: exit_status)
          else
            File.write(kwargs[:command].last, export_jsonl) if export_jsonl
            process_result(exit_status: export_jsonl ? 0 : 1)
          end
        end
      end
    end
  end

  def fixture_lines
    File.readlines(FIXTURE_PATH, chomp: true)
  end

  def completed_lines_with(*extra)
    [
      { record_type: "event", payload_type: "run.session.created", payload: { session_id: "muse-session" } }.to_json,
      *extra,
      {
        record_type: "event",
        payload_type: "run.terminal.completed",
        payload: { outcome: "success", turns: 1, final_text: "done", usage: { input_tokens: 2, output_tokens: 3 } }
      }.to_json
    ]
  end

  it "delegates to an injected runner with the generated session and options" do
    received = nil
    runner = ->(**kwargs) {
      received = kwargs
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: "ok",
        session_id: kwargs[:session_id]
      )
    }

    result = described_class.new(
      "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      runner: runner,
      model: "llama-test",
      reasoning_effort: "high",
      max_model_steps: 12,
      transcript_policy: :exec_jsonl
    ).run

    expect(received).to include(
      workspace_path: "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      model: "llama-test",
      reasoning_effort: "high",
      max_model_steps: 12,
      transcript_policy: :exec_jsonl
    )
    expect(received[:session_id]).to be_present
    expect(result).to be_success
  end

  it "runs muse exec with prompt file and API key stdin, not secret-bearing argv" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "secret prompt text",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      model: "llama-test",
      reasoning_effort: "medium",
      max_model_steps: 7,
      transcript_policy: :exec_jsonl
    ).run

    exec = captured.first
    expect(exec[:command]).to include(
      "muse", "exec",
      "--json",
      "--provider", "meta",
      "--workspace", "/tmp/wkt",
      "--approval-mode", "never",
      "--user-input-auto-resolve",
      "--session-id", "11111111-2222-4333-8444-555555555555",
      "--api-key-stdin",
      "--model", "llama-test",
      "--reasoning-effort", "medium",
      "--max-model-steps", "7"
    )
    expect(exec[:prompt_file_content]).to eq("secret prompt text")
    expect(exec[:stdin_data]).to eq("muse-secret")
    expect(exec[:command].join(" ")).not_to include("muse-secret")
    expect(exec[:command].join(" ")).not_to include("secret prompt text")
    expect(result.session_id).to eq("11111111-2222-4333-8444-555555555555")
  end

  it "parses Local Mode echo-shaped JSONL into the common result shape" do
    events = []
    stub_process_runners(lines: fixture_lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      transcript_policy: :exec_jsonl,
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).to be_success
    expect(result.turns).to eq(1)
    expect(result.outcome).to eq("success")
    expect(result.final_text).to eq("Echo: hello from Syrus")
    expect(result.input_tokens).to eq(12)
    expect(result.output_tokens).to eq(5)
    expect(result.cache_read_input_tokens).to eq(3)
    expect(result.transcript_jsonl).to include('"payload_type":"run.terminal.completed"')
    expect(events).to include([ "[muse diagnostic] internal echo probe task failed after the assistant response", { kind: "system" } ])
  end

  it "uses muse export redacted transcripts by default" do
    captured = []
    export_jsonl = "{\"redacted\":true}\n"
    stub_process_runners(lines: fixture_lines, export_jsonl: export_jsonl, captured: captured)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555"
    ).run

    export = captured.second
    expect(export[:command]).to eq([
      "muse", "export",
      "--session", "11111111-2222-4333-8444-555555555555",
      "--redacted",
      "--out", export[:command].last
    ])
    expect(result.transcript_jsonl).to eq(export_jsonl)
    expect(result.transcript_path).to eq(export[:command].last)
  end

  it "can request raw muse export explicitly" do
    captured = []
    stub_process_runners(lines: fixture_lines, export_jsonl: "{\"raw\":true}\n", captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      transcript_policy: :raw_export
    ).run

    expect(captured.second[:command]).not_to include("--redacted")
  end

  it "falls back to exec JSONL when transcript export fails" do
    events = []
    stub_process_runners(lines: fixture_lines, export_jsonl: nil)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result.transcript_path).to be_nil
    expect(result.transcript_jsonl).to include('"payload_type":"assistant.message"')
    expect(events).to include([ "[muse transcript] export failed (process_failed); falling back to exec JSONL", { kind: "system" } ])
  end

  it "falls back to exec JSONL when muse export is unavailable" do
    events = []
    captured = []
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured << kwargs
      instance_double(ProcessRunner).tap do |runner|
        allow(runner).to receive(:run) do
          if kwargs[:command][0, 2] == %w[muse exec]
            fixture_lines.each { |line| kwargs[:on_output_line].call(line) }
            process_result
          else
            raise Errno::ENOENT, "No such file or directory - muse"
          end
        end
      end
    end

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(captured.second[:command][0, 2]).to eq(%w[muse export])
    expect(result).to be_success
    expect(result.transcript_path).to be_nil
    expect(result.transcript_jsonl).to include('"payload_type":"run.terminal.completed"')
    expect(events).to include([
      "[muse transcript] export command unavailable; falling back to exec JSONL",
      { kind: "system" }
    ])
  end

  it "maps a missing muse executable to a process failure result" do
    runner = instance_double(ProcessRunner)
    allow(runner).to receive(:run)
      .and_raise(Errno::ENOENT, "No such file or directory - muse")
    allow(ProcessRunner).to receive(:new).and_return(runner)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      transcript_policy: :exec_jsonl
    ).run

    expect(result).not_to be_success
    expect(result.outcome).to eq("process_failed")
    expect(result.process_outcome).to eq("process_failed")
    expect(result.session_id).to eq("11111111-2222-4333-8444-555555555555")
    expect(result.final_text).to include("Muse process failed to start")
  end

  it "maps terminal failure events" do
    lines = [
      { record_type: "event", payload_type: "run.terminal.failed", sequence: 1, stream: "stdout", payload: { message: "tool crashed" } }.to_json
    ]
    stub_process_runners(lines: lines)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result).not_to be_success
    expect(result.outcome).to eq("run_failed")
    expect(result.final_text).to eq("tool crashed")
  end

  it "captures malformed JSON startup output with a bounded sanitized message" do
    stub_process_runners(lines: [ "not-json muse-secret #{'x' * 5000}" ], exit_status: 1)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result).not_to be_success
    expect(result.final_text).to start_with("not-json [redacted]")
    expect(result.final_text).not_to include("muse-secret")
    expect(result.final_text.bytesize).to be <= described_class::STARTUP_ERROR_MAX_BYTES
  end

  it "treats malformed startup output as an error even when the process exits cleanly" do
    stub_process_runners(lines: [ "not-json" ], exit_status: 0)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result).not_to be_success
    expect(result.outcome).to eq("error")
    expect(result.final_text).to eq("not-json")
  end

  it "maps process failures when no terminal event is emitted" do
    stub_process_runners(lines: [], exit_status: 42)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result).not_to be_success
    expect(result.outcome).to eq("process_failed")
    expect(result.final_text).to include("process exited with status 42")
  end

  it "maps timeouts when no terminal event is emitted" do
    allow(ProcessRunner).to receive(:new).and_return(
      instance_double(ProcessRunner, run: process_result(exit_status: nil, timed_out: true))
    )

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result).not_to be_success
    expect(result.timed_out).to be true
    expect(result.outcome).to eq("timed_out")
    expect(result.final_text).to include("wall-clock timeout")
  end

  it "maps auth failures to the shared provider auth outcome" do
    lines = [
      { record_type: "event", payload_type: "run.terminal.failed", sequence: 1, stream: "stdout", payload: { message: "HTTP 401 Unauthorized: invalid api key muse-secret" } }.to_json
    ]
    stub_process_runners(lines: lines)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result.outcome).to eq("provider_auth_expired")
    expect(result.final_text).to include("[redacted]")
    expect(result.final_text).not_to include("muse-secret")
  end

  it "maps usage-limit text to the shared provider usage outcome" do
    lines = [
      { record_type: "event", payload_type: "run.terminal.failed", sequence: 1, stream: "stdout", payload: { message: "weekly usage limit for model llama-test has been exhausted" } }.to_json
    ]
    stub_process_runners(lines: lines)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result.outcome).to eq("provider_usage_limit")
    expect(result.final_text).to include("weekly usage limit")
  end

  it "maps structured Muse usage-limit fields to the shared provider usage outcome" do
    lines = [
      {
        record_type: "event",
        payload_type: "run.terminal.failed",
        sequence: 1,
        stream: "stdout",
        payload: {
          error_type: "quota_exhausted",
          code: "model_quota_exhausted",
          message: "Muse request failed for model muse-spark-test"
        }
      }.to_json
    ]
    stub_process_runners(lines: lines)

    result = described_class.new("/tmp/wkt", prompt: "P", api_key: "muse-secret", transcript_policy: :exec_jsonl).run

    expect(result.outcome).to eq("provider_usage_limit")
    expect(result.final_text).to include("Muse request failed")
  end

  it "writes per-home Muse settings with the Syrus MCP sidecar before exec" do
    captured = []
    Dir.mktmpdir("muse-home") do |muse_home|
      stub_process_runners(lines: completed_lines_with, captured: captured)

      result = described_class.new(
        "/tmp/wkt",
        prompt: "P",
        api_key: "muse-secret",
        transcript_policy: :exec_jsonl,
        muse_home: muse_home,
        mcp_server: {
          "syrus-mcp-sidecar" => {
            command: "/app/bin/syrus-mcp-sidecar",
            args: [ "--run-id", "123" ],
            env: { "RAILS_ENV" => "test" }
          }
        }
      ).run

      settings = JSON.parse(File.read(File.join(muse_home, ".config", "muse", "settings.json")))
      expect(result).to be_success
      expect(settings.dig("mcp_servers", "syrus-mcp-sidecar")).to include(
        "command" => "/app/bin/syrus-mcp-sidecar",
        "args" => [ "--run-id", "123" ],
        "env" => { "RAILS_ENV" => "test" }
      )
      expect(captured.first[:env]).to include("HOME" => muse_home, "XDG_CONFIG_HOME" => File.join(muse_home, ".config"))
    end
  end

  it "succeeds required MCP checks when Muse reports the required tool as available" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "mcp.tools",
        payload: {
          servers: [ { name: "syrus-mcp-sidecar", status: "connected" } ],
          tools: [ "syrus-mcp-sidecar.submit_summary" ]
        }
      }.to_json
    )
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_summary]
    ).run

    expect(result).to be_success
  end

  it "succeeds required MCP checks when Muse calls the required tool" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "tool.call",
        payload: {
          server: "syrus-mcp-sidecar",
          tool: "submit_test_plan",
          input: { checks: [] },
          id: "tool-1"
        }
      }.to_json
    )
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_test_plan]
    ).run

    expect(result).to be_success
  end

  it "fails required MCP checks when Muse never exposes required tools" do
    events = []
    captured = []
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "mcp.tools",
        payload: {
          servers: [ { name: "syrus-mcp-sidecar", status: "connected" } ],
          tools: [ "syrus-mcp-sidecar.read_live_state" ]
        }
      }.to_json
    )
    stub_process_runners(lines: lines, captured: captured)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_summary],
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).not_to be_success
    expect(result.outcome).to eq("mcp_sidecar_failed")
    expect(captured.first[:stop_requested].call).to be true
    expect(events).to include([
      "[mcp_required] syrus-mcp-sidecar=connected; required tools missing from Muse tool inventory: submit_summary",
      { kind: "system" }
    ])
  end

  it "does not leak secrets through argv, result text, or logs" do
    captured = []
    events = []
    lines = [
      "startup failed for muse-secret"
    ]
    stub_process_runners(lines: lines, exit_status: 1, captured: captured)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "prompt with private content",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(captured.first[:command].join(" ")).not_to include("muse-secret")
    expect(captured.first[:command].join(" ")).not_to include("prompt with private content")
    expect(result.final_text).not_to include("muse-secret")
    expect(events.join("\n")).not_to include("muse-secret")
  end
end
