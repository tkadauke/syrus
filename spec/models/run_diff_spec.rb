require "rails_helper"

RSpec.describe RunDiff do
  let(:run) { Factories.job(agent_provider: "claude").initial_run }

  it "reads back diffs written through update!, including after reload" do
    run.update!(agent_diff: "full\n", step_agent_diff: "step\n")

    expect(run.agent_diff).to eq("full\n")
    expect(run.step_agent_diff).to eq("step\n")
    fresh = Run.find(run.id)
    expect(fresh.agent_diff).to eq("full\n")
    expect(fresh.step_agent_diff).to eq("step\n")
  end

  it "reads back diffs assigned when a Run is created" do
    job = Factories.job(agent_provider: "claude")
    created = Run.create!(job: job, user: job.user, trigger_kind: "retry", agent_diff: "a", step_agent_diff: "b")

    expect(Run.find(created.id).agent_diff).to eq("a")
    expect(Run.find(created.id).step_agent_diff).to eq("b")
  end

  it "creates the row on first write and updates it on later writes" do
    expect(run.run_diff).to be_nil

    run.update!(agent_diff: "one")
    run.update!(agent_diff: "two", step_agent_diff: "three")

    expect(RunDiff.where(run_id: run.id).count).to eq(1)
    expect(Run.find(run.id).agent_diff).to eq("two")
    expect(Run.find(run.id).step_agent_diff).to eq("three")
  end

  it "does not create a row for a Run that never gets a diff" do
    run.update!(agent_diff: nil, step_agent_diff: nil)

    expect(run.agent_diff).to be_nil
    expect(RunDiff.where(run_id: run.id)).to be_empty
  end

  it "destroys the row with the Run" do
    run.update!(agent_diff: "x")

    expect { run.destroy! }.to change { RunDiff.where(run_id: run.id).count }.from(1).to(0)
  end

  describe "SQL projections" do
    def project(run)
      Run.where(id: run.id).pick(
        Arel.sql("COALESCE(#{described_class.byte_length_sql(:agent_diff)}, 0)"),
        Arel.sql("COALESCE(#{described_class.byte_length_sql(:step_agent_diff)}, 0)"),
        Arel.sql(described_class.step_diff_matches_diff_sql)
      ).then { |a, b, c| [ a.to_i, b.to_i, ActiveModel::Type::Boolean.new.cast(c) ] }
    end

    it "reports bytes and a mismatch for a Run with differing diffs" do
      run.update!(agent_diff: "hello\n", step_agent_diff: "x")

      expect(project(run)).to eq([ "hello\n".bytesize, 1, false ])
    end

    it "reports zero bytes for a Run without a diff row" do
      expect(project(run)).to eq([ 0, 0, false ])
    end

    it "reports a match when the step diff equals the full diff" do
      run.update!(agent_diff: "same", step_agent_diff: "same")

      expect(project(run)).to eq([ 4, 4, true ])
    end
  end
end
