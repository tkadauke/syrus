require "rails_helper"

RSpec.describe App::RunArtifactsPayload do
  it "builds the transcript log + diff payload shared by ownership-scoped and admin-gated callers" do
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
      agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'forum'\n",
      agent_diff_bytes: run.agent_diff.bytesize,
      step_agent_diff: "diff --git a/app.rb b/app.rb\n+puts 'forum'\n",
      logs_count: 2
    )
    expect(payload[:logs].map { |log| log.slice(:sequence, :kind, :chunk) }).to eq([
      { sequence: 0, kind: "stdout", chunk: "first line" },
      { sequence: 1, kind: "stderr", chunk: "second line" }
    ])
  end

  it "defaults agent_diff_bytes to 0 and workflow_id to nil when the run has neither a diff nor a step" do
    job = Factories.job_with_run(step_attrs: { kind: "prepare" }, run_attrs: { state: "queued", step: nil })
    run = job.runs.last

    payload = described_class.build(run: run)

    expect(payload[:agent_diff_bytes]).to eq(0)
    expect(payload[:workflow_id]).to be_nil
    expect(payload[:logs]).to eq([])
  end
end
