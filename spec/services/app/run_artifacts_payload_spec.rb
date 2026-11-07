require "rails_helper"

RSpec.describe App::RunArtifactsPayload do
  it "builds a bounded transcript page shared by ownership-scoped and admin-gated callers" do
    job = Factories.job_with_run(
      run_attrs: {
        state: "succeeded",
        agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'forum'\n",
        step_agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'forum'\n",
        base_sha: "base-sha",
        head_sha: "head-sha"
      }
    )
    run = job.runs.last
    run.job_logs.create!(sequence: 1, kind: "stderr", chunk: "second line")
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "first line")

    payload = described_class.build(run: run)

    expect(payload).to include(
      job_id: job.id,
      workflow_id: run.step.workflow_id,
      run_id: run.id,
      base_ref: "base-sha",
      head_ref: "head-sha",
      artifact: "transcript",
      logs_count: 2,
      logs_page: 1,
      logs_per_page: 100,
      logs_total_pages: 1,
      logs_has_older: false
    )
    expect(payload[:logs].map { |log| log.slice(:sequence, :kind, :chunk) }).to eq([
      { sequence: 0, kind: "stdout", chunk: "first line" },
      { sequence: 1, kind: "stderr", chunk: "second line" }
    ])
  end

  it "paginates newest transcript rows and caps the requested page size" do
    job = Factories.job_with_run
    run = job.runs.last
    run.job_logs.delete_all
    205.times { |sequence| run.job_logs.create!(sequence: sequence, kind: "stdout", chunk: "line #{sequence}") }

    payload = described_class.build(run: run, artifact: "transcript", page: 1, per: 1_000)

    expect(payload).to include(logs_count: 205, logs_page: 1, logs_per_page: 200, logs_total_pages: 2, logs_has_older: true)
    expect(payload[:logs].size).to eq(200)
    expect(payload[:logs].first[:sequence]).to eq(5)
    expect(payload[:logs].last[:sequence]).to eq(204)
  end

  it "includes tool pair context when a call and result straddle transcript pages" do
    job = Factories.job_with_run
    run = job.runs.last
    run.job_logs.delete_all
    JobLog.append!(run: run, chunk: "before", kind: "assistant_text")
    JobLog.append!(run: run, chunk: "call", kind: "tool_call", tool_name: "Read", tool_input: { "file_path" => "app.rb" }, tool_use_id: "split-call")
    JobLog.append!(run: run, chunk: "result", kind: "tool_result", tool_use_id: "split-call", tool_result_content: "contents", tool_result_error: false)
    JobLog.append!(run: run, chunk: "after", kind: "assistant_text")

    newer_page = described_class.build(run: run, artifact: "transcript", page: 1, per: 2)
    older_page = described_class.build(run: run, artifact: "transcript", page: 2, per: 2)

    expect(newer_page).to include(logs_count: 4, logs_page: 1, logs_per_page: 2, logs_total_pages: 2, logs_has_older: true)
    expect(newer_page[:logs].map { |log| log[:chunk] }).to eq(%w[call result after])
    expect(older_page[:logs].map { |log| log[:chunk] }).to eq(%w[before call result])
    expect(newer_page[:logs].first).to include(tool_input: { "file_path" => "app.rb" })
    expect(newer_page[:logs].second).to include(tool_result_content: "contents")
  end

  it "returns only transcript rows after the requested sequence" do
    job = Factories.job_with_run
    run = job.runs.last
    run.job_logs.delete_all
    4.times { |sequence| run.job_logs.create!(sequence: sequence, kind: "stdout", chunk: "line #{sequence}") }

    payload = described_class.build(run: run, after_sequence: 1)

    expect(payload).to include(logs_count: 4, logs_max_sequence: 3, logs_has_newer: false)
    expect(payload[:logs].map { |log| log[:sequence] }).to eq([ 2, 3 ])
  end

  it "returns paired structured call/result metadata for Claude-style and Codex-style workflow MCP events" do
    job = Factories.job_with_run
    run = job.runs.last
    run.job_logs.delete_all
    # Claude: namespaced tool name on the call, result keyed only by tool_use_id.
    JobLog.append!(run: run, chunk: "call", kind: "tool_call", tool_name: "mcp__syrus-mcp-sidecar__submit_adversarial_review",
                   tool_input: { "verdict" => "ok" }, tool_use_id: "toolu_1")
    JobLog.append!(run: run, chunk: "result", kind: "tool_result", tool_use_id: "toolu_1", tool_result_content: "done", tool_result_error: false)
    # Codex: dotted server.tool name, result repeats the name.
    JobLog.append!(run: run, chunk: "[codex mcp] call", kind: "tool_call", tool_name: "syrus-mcp-sidecar.submit_adversarial_review",
                   tool_input: { "verdict" => "ok" }, tool_use_id: "item_2")
    JobLog.append!(run: run, chunk: "[codex mcp] done", kind: "tool_result", tool_name: "syrus-mcp-sidecar.submit_adversarial_review",
                   tool_use_id: "item_2", tool_result_content: { "ok" => true }, tool_result_error: false)

    logs = described_class.build(run: run, artifact: "transcript")[:logs]

    expect(logs.map { |l| [ l[:kind], l[:tool_name], l[:tool_use_id] ] }).to eq(
      [
        [ "tool_call", "mcp__syrus-mcp-sidecar__submit_adversarial_review", "toolu_1" ],
        [ "tool_result", nil, "toolu_1" ],
        [ "tool_call", "syrus-mcp-sidecar.submit_adversarial_review", "item_2" ],
        [ "tool_result", "syrus-mcp-sidecar.submit_adversarial_review", "item_2" ]
      ]
    )
    expect(logs[0][:tool_input]).to eq("verdict" => "ok")
    expect(logs[1]).to include(tool_result_content: "done", tool_result_error: false)
    expect(logs[3][:tool_result_content]).to eq("ok" => true)
  end

  it "reads only the requested diff artifact" do
    job = Factories.job_with_run(run_attrs: { agent_diff: "agent diff", step_agent_diff: "step diff" })
    run = job.runs.last

    agent_payload = described_class.build(run: run, artifact: "agent_diff")
    step_payload = described_class.build(run: run, artifact: "step_agent_diff")

    expect(agent_payload).to include(artifact: "agent_diff", agent_diff: "agent diff", agent_diff_bytes: 10)
    expect(agent_payload).not_to include(:step_agent_diff, :logs)
    expect(step_payload).to include(artifact: "step_agent_diff", step_agent_diff: "step diff", step_agent_diff_bytes: 9)
    expect(step_payload).not_to include(:agent_diff, :logs)
  end

  it "caps oversized diff JSON while reporting its full byte size" do
    diff = "x" * (described_class::MAX_DIFF_BYTES + 10)
    job = Factories.job_with_run(run_attrs: { agent_diff: diff })

    payload = described_class.build(run: job.runs.last, artifact: "agent_diff")

    expect(payload[:agent_diff].bytesize).to eq(described_class::MAX_DIFF_BYTES)
    expect(payload).to include(agent_diff_bytes: diff.bytesize, agent_diff_truncated: true)

    full_payload = described_class.build(run: job.runs.last, artifact: "agent_diff", full: true)
    expect(full_payload).to include(agent_diff: diff, agent_diff_bytes: diff.bytesize, agent_diff_truncated: false)
  end

  it "defaults workflow_id to nil when the run has no step" do
    job = Factories.job_with_run(step_attrs: { kind: "prepare" }, run_attrs: { state: "queued", step: nil })
    run = job.runs.last

    payload = described_class.build(run: run)

    expect(payload[:workflow_id]).to be_nil
    expect(payload[:logs]).to eq([])
  end
end
