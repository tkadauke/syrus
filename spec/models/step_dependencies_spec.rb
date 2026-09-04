require "rails_helper"

# workflow-engine-v3 A5. next_step_id still orders the chain; depends_on_ids
# says what a Step is waiting for, which is what turns "find next" into a
# ready-set query and makes fan-in an edge rather than a sentinel.
RSpec.describe "Step dependency edges" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:steps) { workflow.steps.order(:position).to_a }

  it "wires each materialized step to its predecessor" do
    expect(steps.first.depends_on_step_ids).to eq([])
    expect(steps.second.depends_on_step_ids).to eq([ steps.first.id ])
  end

  it "is ready only once every dependency has settled" do
    first, second = steps.first(2)

    expect(second).not_to be_dependencies_settled

    first.update!(state: "succeeded", finished_at: Time.current)
    expect(second.reload).to be_dependencies_settled
  end

  # A failed dependency is still a settled one. What happens next is the
  # remediation table's business, not the graph's.
  it "treats a failed dependency as settled" do
    first, second = steps.first(2)
    first.update!(state: "failed", finished_at: Time.current)

    expect(second.reload).to be_dependencies_settled
  end

  it "waits for every dependency in a fan-in, not just one" do
    first, second, third = steps.first(3)
    third.update!(depends_on_ids: [ first.id, second.id ])

    first.update!(state: "succeeded", finished_at: Time.current)
    expect(third.reload).not_to be_dependencies_settled

    second.update!(state: "succeeded", finished_at: Time.current)
    expect(third.reload).to be_dependencies_settled
  end

  # A Step materialized before A5 has no edges and must behave exactly as it
  # did: waiting on its linked-list predecessor.
  it "falls back to the linked-list predecessor when it has no edges" do
    first, second = steps.first(2)
    second.update!(depends_on_ids: [])

    expect(second.reload).not_to be_dependencies_settled

    first.update!(state: "succeeded", finished_at: Time.current)
    expect(second.reload).to be_dependencies_settled
  end

  it "seeds an empty edge list rather than null" do
    expect(Step.new.depends_on_ids).to eq([])
  end
end
