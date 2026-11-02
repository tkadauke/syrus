require "rails_helper"

RSpec.describe Maintenance::RepairNonOsPlannedExecutionCapabilities do
  it "audits and repairs not-yet-started Jobs and queued Workflows, then retries admission" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository, state: "blocked_by_epic")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "queued")
    job.update_columns(planned_execution_capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ], "toolchain" => [ "xcode" ], "runtime" => [ "node" ] })
    workflow.update_columns(planned_execution_capabilities: { "os" => [ "macos" ], "runtime" => [ "ruby" ] })
    allow(WorkUnits::Launcher).to receive(:start!).with(workflow)

    result = described_class.call

    expect(result.job_ids).to include(job.id)
    expect(result.workflow_ids).to include(workflow.id)
    expect(job.reload.planned_execution_capabilities).to eq("os" => [ "macos" ])
    expect(workflow.reload.planned_execution_capabilities).to eq("os" => [ "macos" ])
    job_audit = job.planned_execution_overrides.find_by!(workflow: nil)
    workflow_audit = job.planned_execution_overrides.find_by!(workflow: workflow)
    expect(job_audit).to have_attributes(profile: "os_only_data_repair", provenance: "data_migration")
    expect(job_audit.previous_placement.fetch("capabilities")).to include("arch" => [ "arm64" ], "toolchain" => [ "xcode" ])
    expect(workflow_audit.previous_placement.fetch("capabilities")).to include("runtime" => [ "ruby" ])
    expect(WorkUnits::Launcher).to have_received(:start!).with(workflow)
  end

  it "clears no-capable-worker state, unblocks the WorkUnit, and re-enqueues queued Runs" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "queued")
    step = workflow.steps.create!(kind: "prepare", position: 1, state: "queued")
    run = step.runs.create!(job: job, user: user, trigger_kind: "initial", state: "queued")
    intent = WorkIntent.create!(kind: "initial", state: "requested", repository: repository, scope_type: "job", scope_id: job.id)
    unit = WorkUnit.create!(work_intent: intent, kind: "initial", state: "blocked", blocked_reason: "no_capable_worker", repository: repository, scope_type: "job", scope_id: job.id, workflow: workflow)
    unit.work_unit_members.create!(job: job, role: "primary")
    workflow.update_columns(
      planned_execution_capabilities: { "os" => [ "linux" ], "runtime" => [ "node" ] },
      artifacts: { "start_blocked_reason" => "no_capable_worker", "start_blocked_count" => 2 }
    )
    expect_any_instance_of(Run).to receive(:reenqueue!)

    described_class.call

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
    expect(workflow.artifact("start_blocked_count")).to be_nil
    expect(unit.reload).to have_attributes(state: "queued", blocked_reason: nil)
  end

  it "requests reconciliation when immediate re-dispatch fails" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "queued")
    workflow.update_columns(planned_execution_capabilities: { "os" => [ "linux" ], "runtime" => [ "ruby" ] })
    allow(WorkUnits::Launcher).to receive(:start!).with(workflow).and_raise("dispatch failed")
    allow(WorkEngine::Reconciler).to receive(:request)

    described_class.call

    expect(WorkEngine::Reconciler).to have_received(:request).with(source: described_class.name, job: job)
  end

  it "does not alter started Jobs or nonqueued Workflows" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository, state: "running")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "manual", state: "running")
    job.update_columns(planned_execution_capabilities: { "os" => [ "linux" ], "runtime" => [ "node" ] })
    workflow.update_columns(planned_execution_capabilities: { "os" => [ "linux" ], "runtime" => [ "ruby" ] })

    described_class.call

    expect(job.reload.planned_execution_capabilities).to have_key("runtime")
    expect(workflow.reload.planned_execution_capabilities).to have_key("runtime")
  end
end
