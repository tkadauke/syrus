require "rails_helper"
require "tmpdir"
require "open3"

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
      "--disable-approval",
      "--trust-workspace",
      "--disable-sandbox",
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

  # Untrusted, Muse silently drops the workspace's AGENTS.md (a symlink to
  # CLAUDE.md), its .claude/skills, and agent delegation -- it warns and carries
  # on, so the run succeeds while working without the repo's guide. Production
  # ran this way: "rules file ... exists, but the workspace is untrusted, so it
  # is skipped for this session".
  it "trusts the workspace so its rules and project skills load" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).to include("--trust-workspace")
  end

  # --yolo would bundle trust, approval, and sandbox behavior together. Keep
  # the flags explicit so a future CLI change does not silently widen what a
  # workflow run is allowed to do.
  it "uses explicit trust, approval, and sandbox flags instead of --yolo" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).not_to include("--yolo")
    expect(captured.first[:command]).to include("--trust-workspace")
    expect(captured.first[:command]).to include("--approval-mode", "never", "--disable-approval")
    expect(captured.first[:command]).to include("--disable-sandbox")
  end

  it "disables interactive approval prompts for headless workflow runs" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).to include("--approval-mode", "never", "--disable-approval")
  end

  it "disables Muse's nested shell sandbox inside worker containers" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "do it",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).to include("--disable-sandbox")
  end

  it "omits --max-model-steps when max_model_steps is 0" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      max_model_steps: 0,
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).not_to include("--max-model-steps")
  end

  it "omits --max-model-steps when max_model_steps is nil" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      session_id: "11111111-2222-4333-8444-555555555555",
      max_model_steps: nil,
      transcript_policy: :exec_jsonl
    ).run

    expect(captured.first[:command]).not_to include("--max-model-steps")
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

  it "writes per-home Muse settings with the documented schema_version and complete sidecar entry before exec" do
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
      expect(settings["schema_version"]).to eq(1)
      expect(settings).not_to have_key("mcp_servers")
      expect(settings.dig("mcpServers", "syrus-mcp-sidecar")).to eq(
        "transport" => "stdio",
        "command" => "/app/bin/syrus-mcp-sidecar",
        "args" => [ "--run-id", "123" ],
        "env" => { "RAILS_ENV" => "test" },
        "mode" => "required"
      )
      expect(captured.first[:env]).to include("HOME" => muse_home, "XDG_CONFIG_HOME" => File.join(muse_home, ".config"))
    end
  end

  it "repairs a legacy Syrus-written settings file that is missing schema_version, without crashing" do
    Dir.mktmpdir("muse-home") do |muse_home|
      config_dir = File.join(muse_home, ".config", "muse")
      FileUtils.mkdir_p(config_dir)
      settings_path = File.join(config_dir, "settings.json")
      File.write(settings_path, JSON.generate(
        "mcp_servers" => { "old-sidecar" => { "command" => "/old/syrus-mcp-sidecar" } }
      ))
      stub_process_runners(lines: completed_lines_with)

      result = described_class.new(
        "/tmp/wkt",
        prompt: "P",
        api_key: "muse-secret",
        transcript_policy: :exec_jsonl,
        muse_home: muse_home,
        mcp_server: { "syrus-mcp-sidecar" => { command: "/app/bin/syrus-mcp-sidecar", args: [], env: {} } }
      ).run

      settings = JSON.parse(File.read(settings_path))
      expect(result).to be_success
      expect(settings["schema_version"]).to eq(1)
      expect(settings).not_to have_key("mcp_servers")
      expect(settings.dig("mcpServers", "old-sidecar", "command")).to eq("/old/syrus-mcp-sidecar")
      expect(settings.dig("mcpServers", "syrus-mcp-sidecar", "command")).to eq("/app/bin/syrus-mcp-sidecar")
    end
  end

  it "replaces a malformed (non-JSON) existing settings file instead of crashing" do
    Dir.mktmpdir("muse-home") do |muse_home|
      config_dir = File.join(muse_home, ".config", "muse")
      FileUtils.mkdir_p(config_dir)
      settings_path = File.join(config_dir, "settings.json")
      File.write(settings_path, "{not valid json")
      stub_process_runners(lines: completed_lines_with)

      result = described_class.new(
        "/tmp/wkt",
        prompt: "P",
        api_key: "muse-secret",
        transcript_policy: :exec_jsonl,
        muse_home: muse_home,
        mcp_server: { "syrus-mcp-sidecar" => { command: "/app/bin/syrus-mcp-sidecar", args: [], env: {} } }
      ).run

      settings = JSON.parse(File.read(settings_path))
      expect(result).to be_success
      expect(settings["schema_version"]).to eq(1)
      expect(settings.dig("mcpServers", "syrus-mcp-sidecar", "command")).to eq("/app/bin/syrus-mcp-sidecar")
    end
  end

  it "preserves unrelated existing settings when rewriting the file" do
    Dir.mktmpdir("muse-home") do |muse_home|
      config_dir = File.join(muse_home, ".config", "muse")
      FileUtils.mkdir_p(config_dir)
      settings_path = File.join(config_dir, "settings.json")
      File.write(settings_path, JSON.generate("schema_version" => 1, "some_unrelated_setting" => "keep-me"))
      stub_process_runners(lines: completed_lines_with)

      described_class.new(
        "/tmp/wkt",
        prompt: "P",
        api_key: "muse-secret",
        transcript_policy: :exec_jsonl,
        muse_home: muse_home,
        mcp_server: { "syrus-mcp-sidecar" => { command: "/app/bin/syrus-mcp-sidecar", args: [], env: {} } }
      ).run

      settings = JSON.parse(File.read(settings_path))
      expect(settings["some_unrelated_setting"]).to eq("keep-me")
    end
  end

  it "keeps the launcher pinned so the scrubbed env cannot re-enable its update check" do
    captured = []
    stub_process_runners(lines: fixture_lines, captured: captured)

    Dir.mktmpdir("syrus-muse-home-") do |muse_home|
      described_class.new(
        Dir.pwd,
        prompt: "P",
        api_key: "muse-secret",
        transcript_policy: :exec_jsonl,
        muse_home: muse_home
      ).run
    end

    expect(captured.first[:env]).to include("MUSE_NO_AUTO_UPDATE" => "1")
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

  it "succeeds required MCP checks when Muse reports MCP calls as side effect intents" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "task.lifecycle.side_effect_intent",
        payload: {
          event: {
            kind: "side_effect_intent",
            operation: "tool:mcp__syrus_mcp_sidecar__submit_visual_review",
            idempotency_key: "tool:call_01a0b71f4d5677b1815603442e606595"
          }
        }
      }.to_json,
      {
        record_type: "event",
        payload_type: "tool.result",
        payload: {
          call_id: "call_01a0b71f4d5677b1815603442e606595",
          correlation_facts: {
            outcome: "success",
            tool_name: "mcp__syrus_mcp_sidecar__submit_visual_review"
          },
          kind: "tool_result",
          text: "Saved."
        }
      }.to_json
    )
    events = []
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_visual_review],
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).to be_success
    expect(events).to include([
      "● submit_visual_review",
      {
        kind: "tool_call",
        tool_name: "mcp__syrus_mcp_sidecar__submit_visual_review",
        tool_input: {},
        tool_use_id: "call_01a0b71f4d5677b1815603442e606595"
      }
    ])
    expect(events).to include([
      "  ⎿ Saved.",
      {
        kind: "tool_result",
        tool_name: "mcp__syrus_mcp_sidecar__submit_visual_review",
        tool_result_content: "Saved.",
        tool_result_error: false,
        tool_use_id: "call_01a0b71f4d5677b1815603442e606595"
      }
    ])
  end

  it "succeeds required MCP checks when Muse reports MCP calls as committed tool batch effects" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "tool_batch.effect.committed",
        payload: {
          effects: [
            {
              operation: "tool:mcp__syrus_mcp_sidecar__submit_summary",
              idempotency_key: "tool:call_01a0b76d6260768d8d8cdca8646e1d32",
              input: { pr_title: "Add provider override", pr_body: "Body", summary: "Summary" }
            }
          ]
        }
      }.to_json
    )
    events = []
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_summary],
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).to be_success
    expect(events).to include(a_collection_including(
      a_string_including("submit_summary"),
      {
        kind: "tool_call",
        tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
        tool_input: { "pr_title" => "Add provider override", "pr_body" => "Body", "summary" => "Summary" },
        tool_use_id: "call_01a0b76d6260768d8d8cdca8646e1d32"
      }
    ))
  end

  it "succeeds required MCP checks when Muse reports real tool batch records" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "tool_batch.effect.started",
        payload: {
          kind: "tool_batch_effect",
          record: {
            call_id: "call_01a0b76d6260768d8d8cdca8646e1d32",
            tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
            kind: "started"
          }
        }
      }.to_json
    )
    events = []
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_summary],
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).to be_success
    expect(events).to include(a_collection_including(
      a_string_including("submit_summary"),
      {
        kind: "tool_call",
        tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
        tool_input: {},
        tool_use_id: "call_01a0b76d6260768d8d8cdca8646e1d32"
      }
    ))
  end

  it "succeeds required MCP checks when Muse commits assistant tool calls" do
    lines = completed_lines_with(
      {
        record_type: "event",
        payload_type: "assistant_tool_calls_committed",
        payload: {
          records: [
            {
              call_id: "call_01a0b76d6260768d8d8cdca8646e1d32",
              tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
              input: { pr_title: "Add provider override", pr_body: "Body", summary: "Summary" }
            }
          ]
        }
      }.to_json,
      {
        record_type: "event",
        payload_type: "tool_result_batch_committed",
        payload: {
          records: [
            {
              call_id: "call_01a0b76d6260768d8d8cdca8646e1d32",
              tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
              text: "Saved."
            }
          ]
        }
      }.to_json
    )
    events = []
    stub_process_runners(lines: lines)

    result = described_class.new(
      "/tmp/wkt",
      prompt: "P",
      api_key: "muse-secret",
      transcript_policy: :exec_jsonl,
      required_mcp_tools: %w[submit_summary],
      log_sink: ->(chunk, **kwargs) { events << [ chunk, kwargs ] }
    ).run

    expect(result).to be_success
    expect(events).to include(a_collection_including(
      "  ⎿ Saved.",
      {
        kind: "tool_result",
        tool_name: "mcp__syrus_mcp_sidecar__submit_summary",
        tool_result_content: "Saved.",
        tool_result_error: false,
        tool_use_id: "call_01a0b76d6260768d8d8cdca8646e1d32"
      }
    ))
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

  # Optional CLI smoke test: the Ruby specs above are deterministic and don't
  # depend on the muse binary being installed. When it IS available (as in
  # the Syrus worker/dev image), also confirm the real binary accepts the
  # settings file we generate -- this is what actually caught the original
  # bug (`missing field schema_version`), which no amount of pure-Ruby JSON
  # parsing coverage would have caught on its own.
  it "produces a settings.json the installed muse binary does not reject as malformed" do
    muse_path = `which muse 2>/dev/null`.strip
    skip("muse binary not found on PATH; skipping CLI smoke test, deterministic Ruby coverage above stands alone") if muse_path.empty?

    Dir.mktmpdir("muse-home") do |muse_home|
      Dir.mktmpdir("muse-workspace") do |workspace|
        invocation = described_class.new(workspace, prompt: "P", api_key: "muse-secret")
        invocation.send(
          :write_muse_settings!,
          muse_home: muse_home,
          mcp_server: { "syrus-mcp-sidecar" => { command: "/bin/echo", args: [ "hi" ], env: {} } },
          log_sink: ->(*, **) { }
        )

        prompt_path = File.join(workspace, "prompt.txt")
        File.write(prompt_path, "say hi, then stop")
        env = {
          "HOME" => muse_home,
          "XDG_CONFIG_HOME" => File.join(muse_home, ".config"),
          "MUSE_NO_AUTO_UPDATE" => "1"
        }

        settings = JSON.parse(File.read(File.join(muse_home, ".config", "muse", "settings.json")))
        expect(settings).to include("mcpServers")
        expect(settings).not_to include("mcp_servers")

        _stdout, stderr, = Open3.capture3(
          env, "muse", "exec", "--json", "--provider", "echo", "--workspace", workspace,
          "--approval-mode", "never", "--disable-approval", "--disable-sandbox", "--prompt-file", prompt_path
        )

        expect(stderr).not_to include("malformed settings file")
        expect(stderr).not_to include("missing field `schema_version`")
      end
    end
  end
end
