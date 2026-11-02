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
    expect(job.planned_execution_overrides).to all(have_attributes(profile: "os_only_data_repair", provenance: "data_migration"))
    expect(job.planned_execution_overrides.where(workflow: workflow)).to exist
    expect(WorkUnits::Launcher).to have_received(:start!).with(workflow)
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
