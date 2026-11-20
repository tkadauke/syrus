require "rails_helper"

# A landing that cannot place a step on any live worker used to park in flight
# and give up the repository landing slot while still mid-landing, so another
# landing could overlap it on a moved base. It now fails, keeps its approval,
# and is held until a capable worker is live (formal/SyrusModel/LandingSlot.lean).
RSpec.describe LandingCapabilityHold do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) do
    Workflow.create!(
      job: job,
      trigger_kind: "auto_merge",
      state: "running",
      started_at: Time.current,
      planned_execution_capabilities: { "os" => [ "macos" ] },
      planned_execution_source: "explicit"
    )
  end
  let(:step) { Step.create!(workflow: workflow, kind: "prepare", position: 0) }

  def clear_live_workers!
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
  end

  def live_worker!(queue_name, capabilities:)
    ensure_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: "syrus-worker-mac", kind: "worker", last_heartbeat_at: Time.current,
      metadata: { "queues" => [ queue_name ], "capabilities" => capabilities },
      name: "syrus-worker-mac:1", pid: 123, created_at: Time.current
    )
  end

  before do
    clear_live_workers!
    job.update_columns(state: "landing", approved_at: Time.current)
  end

  it "fails a landing that cannot place its next step and records the hold, instead of parking it" do
    expect(StepDispatcher.capability_worker_deferred?(step, workflow, backoff: 1.minute)).to be(true)

    workflow.reload
    expect(workflow).to be_failed
    expect(workflow.failure_reason).to start_with(LandingFailureCode::NO_CAPABLE_WORKER)
    expect(workflow.artifact(described_class::ARTIFACT)).to include(
      "queue" => "merges-macos-arm64",
      "requirements" => { "os" => [ "macos" ] }
    )
    expect(job.reload).to have_attributes(state: "approved", landing_failure_code: LandingFailureCode::NO_CAPABLE_WORKER)
  end

  it "holds re-launch until a capable worker is live" do
    StepDispatcher.capability_worker_deferred?(step, workflow, backoff: 1.minute)

    hold = described_class.active_for([ job.id ])
    expect(hold).to be_present
    expect(hold.reason).to include("waiting for a live worker")

    live_worker!("merges-macos-arm64", capabilities: { "os" => "macos", "arch" => "arm64" })

    expect(described_class.active_for([ job.id ])).to be_nil
  end

  it "is superseded by a later landing attempt" do
    StepDispatcher.capability_worker_deferred?(step, workflow, backoff: 1.minute)
    Workflow.create!(job: job, trigger_kind: "auto_merge", state: "queued")

    expect(described_class.active_for([ job.id ])).to be_nil
  end

  it "keeps the merge-train dispatcher from launching a train for a held Epic" do
    epic = Factories.epic(repository: job.repository, user: job.user)
    job.update_columns(epic_id: epic.id)
    allow_any_instance_of(Epic).to receive(:releases_jobs_for_execution?).and_return(true)
    allow_any_instance_of(Epic).to receive(:landing_dependencies_satisfied?).and_return(true)
    StepDispatcher.capability_worker_deferred?(step, workflow, backoff: 1.minute)

    expect(MergeTrainDispatcher.blocker_reason(epic)).to start_with(LandingFailureCode::NO_CAPABLE_WORKER)
  end
end
