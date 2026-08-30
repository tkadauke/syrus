require "rails_helper"

RSpec.describe Timeline::WorkflowWaterfallQuery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }

  it "returns ordered steps and runs attributed to the parent workflow's worker" do
    workflow = Workflow.create!(
      job: job, trigger_kind: "initial", state: "running",
      started_at: 20.minutes.ago, worker_hostname: "worker-a"
    )
    WorkflowActivity.synchronously do
      WorkflowActivity.record!(event_type: "workflow_started", source: "spec", workflow: workflow, message: "spec")
    end
    WorkflowActivityEvent.where(workflow_id: workflow.id, event_type: "workflow_started")
      .update_all(hostname: "worker-a", pid: 555, queue_role: "runs")
    workflow.update!(worker_storage_key: "storage-a")

    prepare_step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 20.minutes.ago, finished_at: 19.minutes.ago)
    implement_step = workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 19.minutes.ago)
    run = Run.create!(
      job: job, user: user, step: implement_step, trigger_kind: "initial", agent_provider: "claude",
      state: "running", started_at: 19.minutes.ago, last_heartbeat_at: 1.minute.ago
    )

    result = described_class.call(workflow_id: workflow.id)

    expect(result[:workflow]).to include(id: workflow.id, job_id: job.id, worker_storage_key: "storage-a", queue_role: "runs", hostname: "worker-a", pid: 555)
    expect(result[:steps].map { |step| step[:id] }).to eq([ prepare_step.id, implement_step.id ])
    expect(result[:steps].first).to include(kind: "prepare", status: "succeeded", worker_storage_key: "storage-a", queue_role: "runs", hostname: "worker-a", pid: 555)

    implement_payload = result[:steps].second
    expect(implement_payload[:runs]).to contain_exactly(
      include(id: run.id, status: "running", last_heartbeat_at: run.last_heartbeat_at.iso8601)
    )
  end

  it "raises RecordNotFound for an unknown workflow id" do
    expect { described_class.call(workflow_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "attaches the workflow's blocked-reason explanation to the workflow payload and to not-yet-started steps only" do
    queued_job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: queued_job)
    workflow.update!(started_at: 20.minutes.ago, state: "running", worker_hostname: "worker-a")

    steps = workflow.steps.order(:position).to_a
    started_step = steps.first
    started_step.update!(state: "succeeded", started_at: 20.minutes.ago, finished_at: 19.minutes.ago)
    queued_step = steps.second

    workflow.work_unit.block!(reason: "provider_availability", blocked_until: 10.minutes.from_now, details: { "provider" => "codex" })

    result = described_class.call(workflow_id: workflow.id)

    expect(result[:workflow][:blocked]).to include(
      blocked_reason: "provider_availability",
      blocked_details: { "provider" => "codex" },
      available: true
    )

    started_payload = result[:steps].find { |step| step[:id] == started_step.id }
    queued_payload = result[:steps].find { |step| step[:id] == queued_step.id }
    expect(started_payload).not_to have_key(:blocked)
    expect(queued_payload[:blocked]).to eq(result[:workflow][:blocked])
  end
end
