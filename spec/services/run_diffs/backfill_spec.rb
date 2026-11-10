require "rails_helper"

RSpec.describe RunDiffs::Backfill do
  # The legacy columns are dropped from the schema; recreate them for the
  # duration of the example (SQLite DDL is transactional, so this rolls back).
  before do
    conn = ActiveRecord::Base.connection
    conn.add_column :runs, :agent_diff, :text unless conn.column_exists?(:runs, :agent_diff)
    conn.add_column :runs, :step_agent_diff, :text unless conn.column_exists?(:runs, :step_agent_diff)
    Run.reset_column_information
  end

  after { Run.reset_column_information }

  def legacy_run(agent_diff: nil, step_agent_diff: nil)
    run = Factories.job(agent_provider: "claude").initial_run
    Run.where(id: run.id).update_all(agent_diff: agent_diff, step_agent_diff: step_agent_diff)
    run
  end

  it "copies runs with either or both diffs and skips runs with neither" do
    only_full = legacy_run(agent_diff: "full")
    only_step = legacy_run(step_agent_diff: "step")
    both = legacy_run(agent_diff: "f", step_agent_diff: "s")
    neither = legacy_run
    empty = legacy_run(agent_diff: "", step_agent_diff: "")

    expect(described_class.new(batch_size: 2).call).to eq(3)

    rows = RunDiff.all.index_by(&:run_id)
    expect(rows.keys).to contain_exactly(only_full.id, only_step.id, both.id)
    expect(rows[only_full.id].agent_diff).to eq("full")
    expect(rows[only_full.id].step_agent_diff).to be_nil
    expect(rows[only_step.id].agent_diff).to be_nil
    expect(rows[only_step.id].step_agent_diff).to eq("step")
    expect(rows[both.id].attributes.values_at("agent_diff", "step_agent_diff")).to eq(%w[f s])
    expect(RunDiff.where(run_id: [ neither.id, empty.id ])).to be_empty
  end

  it "is idempotent and never overwrites an existing row" do
    run = legacy_run(agent_diff: "legacy")
    other = legacy_run(agent_diff: "other")
    RunDiff.create!(run_id: other.id, agent_diff: "newer")

    described_class.new.call
    snapshot = RunDiff.order(:run_id).pluck(:run_id, :agent_diff, :step_agent_diff)
    expect(described_class.new.call).to eq(0)

    expect(RunDiff.order(:run_id).pluck(:run_id, :agent_diff, :step_agent_diff)).to eq(snapshot)
    expect(RunDiff.where(run_id: run.id).count).to eq(1)
    expect(RunDiff.find_by!(run_id: other.id).agent_diff).to eq("newer")
  end
end
