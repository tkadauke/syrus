require "rails_helper"

RSpec.describe WorkflowWorkspaceLifecycle do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(repository: repository, user: user) }
  let(:workflow) { Workflow.create!(job: job, user: user, trigger_kind: "manual") }

  it "keeps last-known ownership when routing affinity is cleared after storage loss" do
    described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")

    described_class.clear_routing_affinity!(
      workflow,
      actor: "repair_queue_affinity",
      reason: "resume queue has no live worker"
    )

    expect(workflow.reload).to have_attributes(
      worker_hostname: nil,
      worker_storage_key: nil,
      last_workspace_hostname: "worker-a",
      last_workspace_storage_key: "storage-a",
      workspace_lifecycle_state: "storage_lost"
    )
    expect(workflow.workflow_workspace_events.last).to have_attributes(
      event_type: "storage_lost",
      hostname: "worker-a",
      storage_key: "storage-a",
      actor: "repair_queue_affinity",
      reason: "resume queue has no live worker"
    )
  end

  it "records ownership transfers without overwriting the earlier event evidence" do
    described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")
    described_class.record_identity!(workflow, hostname: "worker-b", storage_key: "storage-b")

    event = workflow.workflow_workspace_events.last
    expect(event).to have_attributes(
      event_type: "ownership_transferred",
      hostname: "worker-b",
      storage_key: "storage-b"
    )
    expect(event.details).to eq(
      "previous_hostname" => "worker-a",
      "previous_storage_key" => "storage-a"
    )
  end

  it "distinguishes initial creation from reconstruction" do
    described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")
    described_class.created!(workflow)
    described_class.storage_lost!(workflow, actor: "repair", reason: "disk unavailable")
    described_class.created!(workflow)

    expect(workflow.reload.workspace_lifecycle_state).to eq("reconstructed")
    expect(workflow.workflow_workspace_events.order(:id).pluck(:event_type))
      .to eq(%w[created storage_lost reconstructed])
  end
end
