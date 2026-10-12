require "rails_helper"

RSpec.describe PreviousGraderFailures do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "merge_train") }

  def grader_step(iteration:, name: "rspec", loop_id: "loop-1", state: "succeeded")
    Step.create!(workflow: workflow, kind: "grader", position: iteration * 10, iteration: iteration,
                 loop_id: loop_id, state: state, details: { "name" => name })
  end

  it "returns the spec files the same grader failed one iteration back" do
    previous = grader_step(iteration: 1, state: "failed")
    run = previous.runs.create!(job: job, trigger_kind: "manual")
    allow(TestEvidenceLookup).to receive(:failed_test_cases_for).with(run, "rspec").and_return([
      { "file_path" => "spec/b_spec.rb" },
      { "file_path" => "spec/a_spec.rb" },
      { "file_path" => "spec/a_spec.rb" }
    ])

    expect(described_class.spec_paths_for(grader_step(iteration: 2))).to eq([ "spec/a_spec.rb", "spec/b_spec.rb" ])
  end

  it "is empty on the first iteration" do
    expect(described_class.spec_paths_for(grader_step(iteration: 1))).to eq([])
  end

  # Fanout can pick a different grader set per iteration, so the previous step
  # is matched by grader name rather than position.
  it "ignores a different grader's failures" do
    previous = grader_step(iteration: 1, name: "e2e", state: "failed")
    run = previous.runs.create!(job: job, trigger_kind: "manual")
    allow(TestEvidenceLookup).to receive(:failed_test_cases_for).and_return([ { "file_path" => "spec/e2e_spec.rb" } ])

    expect(described_class.spec_paths_for(grader_step(iteration: 2, name: "rspec"))).to eq([])
  end

  it "is empty outside a loop" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 1, iteration: 2,
                        loop_id: nil, state: "queued", details: { "name" => "rspec" })

    expect(described_class.spec_paths_for(step)).to eq([])
  end
end
