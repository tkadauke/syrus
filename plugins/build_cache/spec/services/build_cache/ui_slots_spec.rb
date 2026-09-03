require "rails_helper"

RSpec.describe BuildCache::UiSlots do
  let(:job) { Factories.job }

  it "contributes nothing when the Job has no capture" do
    expect(described_class.ui_slots(slot: "job.detail", context: { job: job })).to eq([])
  end

  it "contributes nothing to other slots" do
    expect(described_class.ui_slots(slot: "repository.detail", context: { job: job })).to eq([])
  end

  it "carries the latest capture as panel props" do
    workflow = job.workflows.first || Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    BuildCache::StatsArtifact.record!(
      workflow, run: job.initial_run, step_kind: "grader", label: "rspec",
      stats: { "stats" => { "cache_hits" => 3, "cache_misses" => 1 } }
    )

    panel = described_class.ui_slots(slot: "job.detail", context: { job: job.reload }).sole

    expect(panel[:component]).to eq("build_cache/SccacheCard")
    expect(panel.dig(:props, :sccache, :workflow_id)).to eq(workflow.id)
  end

  it "prefers the freshest capture across workflows, not the newest workflow" do
    older = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    newer = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "running")
    BuildCache::StatsArtifact.record!(older, run: job.initial_run, step_kind: "grader", label: "late", stats: { "a" => 1 })
    older.reload.set_artifact!("sccache_stats", BuildCache::StatsArtifact.read(older).map { |e| e.merge("captured_at" => "2030-01-01T00:00:00Z") })
    BuildCache::StatsArtifact.record!(newer, run: job.initial_run, step_kind: "grader", label: "early", stats: { "b" => 2 })

    panel = described_class.ui_slots(slot: "job.detail", context: { job: job.reload }).sole

    expect(panel.dig(:props, :sccache, :workflow_id)).to eq(older.id)
  end
end
