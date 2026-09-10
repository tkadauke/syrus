require "rails_helper"

RSpec.describe TargetHealthRecorder do
  let(:job) { job_with_run }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first }

  it "records target health and leaves workflow artifacts as references" do
    record = described_class.record!(
      repository: job.repository,
      workflow: workflow,
      step: step,
      run: run,
      target_label: "//:grade/rspec",
      project_id: "repo",
      commit_sha: "abc123",
      input_fingerprint: "input-fp",
      command_fingerprint: "command-fp",
      environment_fingerprint: "env-fp",
      status: "passed",
      started_at: 5.seconds.ago,
      finished_at: Time.current,
      duration_s: 5.0,
      artifacts: { "log_path" => "workflow/rspec.log" },
      metadata: { "trigger_kind" => "initial" }
    )

    expect(record).to have_attributes(
      repository: job.repository,
      workflow: workflow,
      step: step,
      run: run,
      target_label: "//:grade/rspec",
      project_id: "repo",
      status: "passed",
      duration_s: 5.0
    )
    expect(record.artifacts).to eq("log_path" => "workflow/rspec.log")

    refs = workflow.reload.artifact(TargetHealthRecorder::WORKFLOW_ARTIFACT_KEY)
    expect(refs).to eq([
      {
        "target_health_record_id" => record.id,
        "target_label" => "//:grade/rspec",
        "project_id" => "repo",
        "commit_sha" => "abc123",
        "status" => "passed"
      }
    ])
  end

  it "updates an existing target health record for the same fingerprint tuple" do
    first = record_target(status: "unknown", artifacts: { "attempt" => 1 })
    updated = record_target(status: "failed", artifacts: { "attempt" => 2 })

    expect(updated.id).to eq(first.id)
    expect(TargetHealthRecord.count).to eq(1)
    expect(updated.reload).to have_attributes(status: "failed", artifacts: { "attempt" => 2 })
    expect(workflow.reload.artifact(TargetHealthRecorder::WORKFLOW_ARTIFACT_KEY).size).to eq(1)
  end

  private

  def record_target(status:, artifacts:)
    described_class.record!(
      repository: job.repository,
      workflow: workflow,
      step: step,
      run: run,
      target_label: "//:grade/rspec",
      project_id: "repo",
      commit_sha: "abc123",
      input_fingerprint: "input-fp",
      command_fingerprint: "command-fp",
      environment_fingerprint: "env-fp",
      status: status,
      artifacts: artifacts
    )
  end
end
