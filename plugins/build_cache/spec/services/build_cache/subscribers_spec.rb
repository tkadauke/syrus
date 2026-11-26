require "rails_helper"

RSpec.describe BuildCache::Subscribers do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:run) { job.initial_run }

  def event(overrides = {})
    Syrus::DomainEvent.new(
      name: "step.command.completed",
      payload: {
        run_id: run.id, workflow_id: workflow.id, job_id: job.id,
        step_kind: "grader", label: "rspec",
        workspace_path: "/tmp/does-not-matter", env: {}
      }.merge(overrides)
    )
  end

  it "records a capture as a workflow artifact" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return({ "cache_hits" => 4 })

    described_class.on_command_completed(event)

    entry = BuildCache::StatsArtifact.read(workflow.reload).last
    expect(entry["step_kind"]).to eq("grader")
    expect(entry["stats"]).to eq({ "cache_hits" => 4 })
  end

  it "records nothing when sccache is unavailable" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return(nil)

    described_class.on_command_completed(event)

    expect(BuildCache::StatsArtifact.read(workflow.reload)).to eq([])
  end

  it "ignores an event whose run has gone away" do
    expect { described_class.on_command_completed(event(run_id: 0)) }.not_to raise_error
  end

  it "is reached through the inline event published by a step" do
    allow(BuildCache::StatsCapture).to receive(:capture).and_return({ "cache_hits" => 9 })

    Syrus::Events.publish(
      "step.command.completed",
      run_id: run.id, workflow_id: workflow.id, job_id: job.id,
      step_kind: "prepare", label: "bundle install",
      workspace_path: "/tmp/does-not-matter", env: {}
    )

    expect(BuildCache::StatsArtifact.read(workflow.reload).last["step_kind"]).to eq("prepare")
  end
end
