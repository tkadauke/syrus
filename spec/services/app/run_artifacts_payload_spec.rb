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

  it "defaults workflow_id to nil when the run has no step" do
    job = Factories.job_with_run(step_attrs: { kind: "prepare" }, run_attrs: { state: "queued", step: nil })
    run = job.runs.last

    payload = described_class.build(run: run)

    expect(payload[:workflow_id]).to be_nil
    expect(payload[:logs]).to eq([])
  end
end
