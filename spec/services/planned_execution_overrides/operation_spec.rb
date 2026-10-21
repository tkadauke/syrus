require "rails_helper"

RSpec.describe PlannedExecutionOverrides::Operation do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "queued") }
  let(:step) { workflow.steps.create!(kind: "prepare", position: 1, state: "queued") }
  let(:run) { step.runs.create!(job: job, user: user, trigger_kind: "initial", state: "queued") }

  def operation(profile: "linux", reason: "Correct classifier placement", expected_revision: nil)
    described_class.new(job: job, profile: profile, actor: user, reason: reason, provenance: "spec", expected_revision: expected_revision)
  end

  it "updates a queued zero-start Run Job and Workflow, audits it, and re-resolves the queued Run" do
    run
    job.update!(planned_execution_capabilities: ExecutionPlacementProfile.fetch("ios_xcode").capabilities, planned_execution_source: "classifier")
    workflow.update!(planned_execution_capabilities: ExecutionPlacementProfile.fetch("ios_xcode").capabilities, planned_execution_source: "classifier")
    expect_any_instance_of(Run).to receive(:reenqueue!)

    result = operation.apply!

    expect(result.as_json).to include(eligible: true, profile: "linux")
    expect(job.reload.planned_execution_capabilities).to eq("os" => [ "linux" ])
    expect(workflow.reload.planned_execution_capabilities).to eq("os" => [ "linux" ])
    expect(job.planned_execution_overrides.sole).to have_attributes(user: user, profile: "linux", provenance: "spec", reason: "Correct classifier placement")
  end

  it "updates backlog placement before an initial Workflow exists" do
    job.workflows.destroy_all
    job.update!(state: "backlog")

    expect(operation(profile: "macos_desktop").apply!.workflow).to be_nil
    expect(job.reload.planned_execution_capabilities).to eq(ExecutionPlacementProfile.fetch("macos_desktop").capabilities)
  end

  it "starts a queued initial Workflow with no Run after changing its lane" do
    empty_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    allow(WorkUnits::Launcher).to receive(:start!).with(empty_workflow).and_return(double(run: nil))

    operation(profile: "macos_desktop").apply!

    expect(empty_workflow.reload.planned_execution_capabilities).to eq(ExecutionPlacementProfile.fetch("macos_desktop").capabilities)
    expect(WorkUnits::Launcher).to have_received(:start!).with(empty_workflow)
  end

  it "refuses running work and a Run that has started" do
    job.update!(state: "running")
    expect(operation.inspect.reason).to include("once #{job.slug} is running")

    job.update!(state: "queued")
    run.update_columns(started_at: Time.current)
    expect(operation.inspect.reason).to include("has already started")
  end

  it "refuses a queued Job when another Workflow or Run exists outside the initial attempt" do
    run
    retry_workflow = Workflow.create!(job: job, user: user, trigger_kind: "retry", state: "failed")
    retry_step = retry_workflow.steps.create!(kind: "implement", position: 1, state: "failed")
    retry_step.runs.create!(job: job, user: user, trigger_kind: "retry", state: "failed", started_at: 1.minute.ago)

    inspection = operation.inspect

    expect(inspection.eligible).to be(false)
    expect(inspection.reason).to include("without exactly one initial Workflow")
    expect { operation.apply! }.to raise_error(described_class::Unsafe, /without exactly one initial Workflow/)
    expect(job.reload.planned_execution_overrides).to be_empty
  end

  it "refuses backlog placement when any execution history already exists" do
    run
    job.update!(state: "backlog")

    expect(operation.inspect.reason).to include("already has Workflow or Run history")
  end

  it "commits placement and requests durable reconciliation when replacement enqueue fails" do
    run
    allow_any_instance_of(Run).to receive(:reenqueue!).and_raise(ActiveJob::EnqueueError, "queue unavailable")
    expect(WorkEngine::Reconciler).to receive(:request).with(source: described_class.name, job: job)

    result = operation(profile: "macos_desktop").apply!

    expect(result.dispatch_status).to eq("reconciliation_requested")
    expect(result.dispatch_error).to include("queue unavailable")
    expect(job.reload.planned_execution_capabilities).to eq(ExecutionPlacementProfile.fetch("macos_desktop").capabilities)
    expect(workflow.reload.planned_execution_capabilities).to eq(ExecutionPlacementProfile.fetch("macos_desktop").capabilities)
    expect(run.reload).to be_queued
    expect(job.planned_execution_overrides.sole).to be_present
  end

  it "leaves durable queued work for the recurring reconciler when the immediate recovery enqueue also fails" do
    run
    allow_any_instance_of(Run).to receive(:reenqueue!).and_raise(ActiveJob::EnqueueError, "runs queue unavailable")
    allow(WorkEngine::Reconciler).to receive(:request).and_raise(ActiveJob::EnqueueError, "control queue unavailable")

    result = operation(profile: "linux").apply!

    expect(result.dispatch_status).to eq("reconciliation_requested")
    expect(run.reload).to be_queued
    expect(workflow.reload).to be_queued
    expect(job.planned_execution_overrides.sole).to be_present
  end

  it "refuses a stale confirmed repair without partial updates" do
    before = job.planned_execution_json
    stale_revision = job.entity_revision
    job.update!(priority: "high")

    expect { operation(profile: "macos_desktop", expected_revision: stale_revision).apply! }
      .to raise_error(described_class::Unsafe, /changed after the repair was proposed/)
    expect(job.reload.planned_execution_json).to eq(before)
    expect(job.planned_execution_overrides).to be_empty
  end

  it "keeps macOS desktop distinct from iOS/Xcode and rejects unknown profiles" do
    desktop = operation(profile: "macos_desktop").inspect.after.fetch("capabilities")
    ios = operation(profile: "ios_xcode").inspect.after.fetch("capabilities")

    expect(desktop).not_to have_key("toolchain")
    expect(ios).to include("toolchain" => [ "xcode" ], "runtime" => [ "ios_simulator" ])
    expect { operation(profile: "windows") }.to raise_error(ArgumentError, /unknown execution placement profile/)
  end
end
