require "rails_helper"

RSpec.describe Timeline::WorkerAttribution do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }

  it "prefers workflow activity queue role and pid while taking storage identity from the workflow" do
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "running",
      started_at: 10.minutes.ago,
      worker_hostname: "worker-column",
      worker_storage_key: "storage-a"
    )
    WorkflowActivityEvent.create!(
      occurred_at: 9.minutes.ago,
      event_type: "run_started",
      source: "spec",
      severity: "info",
      hostname: "worker-event",
      pid: 1234,
      queue_role: "runs",
      workflow: workflow,
      message: "run started",
      metadata: {}
    )

    expect(described_class.for_workflows([ workflow ])).to eq(
      workflow.id => {
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-event",
        pid: 1234
      }
    )
  end

  it "prefers the earliest activity event with a queue role over an earlier unattributed workflow event" do
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "running",
      started_at: 10.minutes.ago,
      worker_hostname: "worker-column",
      worker_storage_key: "storage-a"
    )
    WorkflowActivityEvent.create!(
      occurred_at: 9.minutes.ago,
      event_type: "workflow_started",
      source: "spec",
      severity: "info",
      hostname: "worker-dispatcher",
      pid: 1111,
      queue_role: nil,
      workflow: workflow,
      message: "workflow started",
      metadata: {}
    )
    WorkflowActivityEvent.create!(
      occurred_at: 8.minutes.ago,
      event_type: "run_started",
      source: "spec",
      severity: "info",
      hostname: "worker-runner",
      pid: 2222,
      queue_role: "runs",
      workflow: workflow,
      message: "run started",
      metadata: {}
    )

    expect(described_class.for_workflows([ workflow ])).to eq(
      workflow.id => {
        worker_storage_key: "storage-a",
        queue_role: "runs",
        hostname: "worker-runner",
        pid: 2222
      }
    )
  end

  it "falls back through spawned process, workflow hostname, and nil attribution" do
    workflow_with_process = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "succeeded",
      started_at: 20.minutes.ago,
      finished_at: 15.minutes.ago,
      worker_storage_key: "storage-b"
    )
    SpawnedProcess.create!(
      workflow: workflow_with_process,
      kind: "agent",
      command: "codex",
      hostname: "worker-process",
      pid: 2222,
      started_at: 20.minutes.ago,
      finished_at: 15.minutes.ago
    )
    workflow_with_columns = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "succeeded",
      started_at: 14.minutes.ago,
      finished_at: 10.minutes.ago,
      worker_hostname: "worker-column",
      worker_storage_key: "storage-c"
    )
    unattributed = Workflow.create!(
      job: job,
      trigger_kind: "manual",
      state: "queued"
    )

    result = described_class.for_workflows([ workflow_with_process, workflow_with_columns, unattributed ])

    expect(result[workflow_with_process.id]).to eq(
      worker_storage_key: "storage-b",
      queue_role: nil,
      hostname: "worker-process",
      pid: 2222
    )
    expect(result[workflow_with_columns.id]).to eq(
      worker_storage_key: "storage-c",
      queue_role: nil,
      hostname: "worker-column",
      pid: nil
    )
    expect(result[unattributed.id]).to eq(
      worker_storage_key: nil,
      queue_role: nil,
      hostname: nil,
      pid: nil
    )
  end
end
