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

  it "preserves an existing routing component when only one identity component is reported" do
    described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")

    described_class.record_identity!(workflow, hostname: "worker-b", storage_key: nil)
    expect(workflow.reload).to have_attributes(
      worker_hostname: "worker-b",
      worker_storage_key: "storage-a",
      last_workspace_hostname: "worker-b",
      last_workspace_storage_key: "storage-a"
    )

    described_class.record_identity!(workflow, hostname: nil, storage_key: "storage-b")
    expect(workflow.reload).to have_attributes(
      worker_hostname: "worker-b",
      worker_storage_key: "storage-b",
      last_workspace_hostname: "worker-b",
      last_workspace_storage_key: "storage-b"
    )
  end

  it "does not write or record an event when the identity is unchanged" do
    described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")
    allow(workflow).to receive(:update_columns).and_call_original

    expect {
      described_class.record_identity!(workflow, hostname: "worker-a", storage_key: "storage-a")
    }.not_to change { workflow.workflow_workspace_events.count }
    expect(workflow).not_to have_received(:update_columns)
  end

  it "does not record storage loss when there is no routing affinity to clear" do
    workflow.update_columns(last_workspace_hostname: "worker-a", last_workspace_storage_key: "storage-a")

    expect {
      described_class.clear_routing_affinity!(workflow, actor: "repair", reason: "stale repair")
    }.not_to change { workflow.workflow_workspace_events.count }
    expect(workflow.reload.workspace_lifecycle_state).to be_nil
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

  it "classifies a rebuilt pre-migration workspace as reconstructed" do
    workflow.update_columns(
      last_workspace_hostname: "legacy-worker",
      last_workspace_storage_key: "legacy-storage",
      workspace_lifecycle_state: "created"
    )

    described_class.created!(workflow)

    expect(workflow.reload.workspace_lifecycle_state).to eq("reconstructed")
    expect(workflow.workflow_workspace_events.last.event_type).to eq("reconstructed")
  end
end
