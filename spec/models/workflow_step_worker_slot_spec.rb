require "rails_helper"

RSpec.describe WorkflowStepWorkerSlot, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) do
    workflow.first_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
  end

  it "acquires one active slot per worker storage key" do
    slot = described_class.acquire!(run: run, hostname: "worker-a", storage_key: "storage-a")

    expect(slot).to be_persisted
    expect(slot).to have_attributes(
      workflow: workflow,
      step: workflow.first_step,
      slot_key: "storage-a",
      slot_key_source: "worker_storage_key",
      active_slot_key: "storage-a"
    )
  end

  it "rejects a second active holder of the same slot until the first releases" do
    first = described_class.acquire!(run: run, hostname: "worker-a", storage_key: "storage-a")
    other_job = Factories.job_record(user: user, repository: repository, state: "queued", issue_number: 778)
    other_workflow = Workflows::Initial.instantiate(job: other_job, agent_provider: "codex")
    other_run = other_workflow.first_step.runs.create!(
      job: other_job,
      trigger_kind: other_workflow.trigger_kind,
      agent_provider: other_workflow.agent_provider
    )

    expect {
      described_class.acquire!(run: other_run, hostname: "worker-a", storage_key: "storage-a")
    }.to raise_error(described_class::Conflict)

    first.release!(reason: "test_release")

    expect {
      described_class.acquire!(run: other_run, hostname: "worker-a", storage_key: "storage-a")
    }.to change(described_class.active, :count).by(1)
  end

  it "falls back to hostname when the durable storage key is unavailable" do
    slot = described_class.acquire!(run: run, hostname: "worker-a", storage_key: nil)

    expect(slot).to have_attributes(
      slot_key: "worker-a",
      slot_key_source: "hostname"
    )
  end

  it "releases active slots whose runs are no longer running" do
    run.update!(state: "running", started_at: Time.current)
    slot = described_class.acquire!(run: run, hostname: "worker-a", storage_key: "storage-a")
    slot.update_columns(acquired_at: (described_class::STALE_INACTIVE_GRACE + 1.minute).ago)
    run.update_columns(state: "failed", finished_at: Time.current)

    described_class.release_inactive_holders!

    expect(slot.reload).to have_attributes(
      released_at: be_present,
      active_slot_key: nil,
      release_reason: "inactive_run"
    )
  end

  it "does not release a just-acquired slot before its Run reaches running" do
    slot = described_class.acquire!(run: run, hostname: "worker-a", storage_key: "storage-a")

    described_class.release_inactive_holders!

    expect(slot.reload).to have_attributes(
      released_at: nil,
      active_slot_key: "storage-a"
    )
  end
end
