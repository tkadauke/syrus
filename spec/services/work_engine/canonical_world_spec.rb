require "rails_helper"

# The canonical world is the DOC-44 oracle's input (formal/Oracle.lean). These
# examples hold the export to the kernel's schema and to its Valid predicate,
# so a world the oracle would reject is caught here without Lean installed.
RSpec.describe WorkEngine::CanonicalWorld do
  def valid_like_the_kernel?(world)
    ids = ->(name) { world.fetch(name).map { |row| row.fetch("id") } }
    intent_ids = ids.("intents")
    unit_ids = ids.("units")
    workflow_ids = ids.("workflows")
    step_ids = ids.("steps")

    %w[intents units workflows steps runs].all? { |name| ids.(name).uniq.size == ids.(name).size } &&
      world.fetch("locks").map { |lock| lock.fetch("key") }.uniq.size == world.fetch("locks").size &&
      world.fetch("units").all? do |unit|
        intent_ids.include?(unit.fetch("intent")) && (unit.fetch("workflow").nil? || workflow_ids.include?(unit.fetch("workflow")))
      end &&
      world.fetch("steps").all? { |step| workflow_ids.include?(step.fetch("workflow")) } &&
      world.fetch("runs").all? { |run| step_ids.include?(run.fetch("step")) } &&
      world.fetch("locks").all? { |lock| unit_ids.include?(lock.fetch("unit")) }
  end

  it "exports a launched Job's work in the kernel schema" do
    job = Factories.job_record(state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)

    world = described_class.export(jobs: [ job ])

    expect(world.keys).to contain_exactly("intents", "units", "workflows", "steps", "runs", "locks")
    expect(world.fetch("workflows")).to eq([ { "id" => workflow.id, "state" => "queued" } ])
    expect(world.fetch("units")).to eq([
      { "id" => workflow.work_unit.id, "intent" => workflow.work_unit.work_intent_id, "workflow" => workflow.id, "state" => "queued" }
    ])
    expect(world.fetch("steps").map { |step| step.fetch("workflow") }.uniq).to eq([ workflow.id ])
    expect(world.fetch("locks").map { |lock| lock.fetch("unit") }.uniq).to eq([ workflow.work_unit.id ])
    expect(valid_like_the_kernel?(world)).to be true
  end

  it "exports the lost-cleanup world the oracle fixture describes" do
    job = Factories.job_record(state: "failed")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    step = workflow.steps.order(:position).first
    workflow.steps.where.not(id: step.id).delete_all
    workflow.update_columns(state: "failed", finished_at: 1.minute.ago)
    step.update_columns(state: "running")
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "running")
    workflow.work_unit.update_columns(state: "running")

    world = described_class.export(jobs: [ job ])

    expect(world.fetch("workflows")).to eq([ { "id" => workflow.id, "state" => "failed" } ])
    expect(world.fetch("steps")).to eq([ { "id" => step.id, "workflow" => workflow.id, "state" => "running" } ])
    expect(world.fetch("runs")).to eq([ { "id" => run.id, "step" => step.id, "state" => "running" } ])
    expect(world.fetch("units").sole).to include("state" => "running", "workflow" => workflow.id)
    expect(world.fetch("locks")).not_to be_empty
    expect(valid_like_the_kernel?(world)).to be true
  end

  it "includes the Workflow of a unit found only through its members" do
    job = Factories.job_record(state: "running")
    other = Factories.job_record(user: job.user, repository: job.repository, state: "running")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: other)
    workflow.work_unit.work_unit_members.create!(job: job, role: "member")

    world = described_class.export(jobs: [ job ])

    expect(world.fetch("workflows").map { |row| row.fetch("id") }).to include(workflow.id)
    expect(valid_like_the_kernel?(world)).to be true
  end
end
