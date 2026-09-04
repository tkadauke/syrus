require "rails_helper"

# workflow-engine-v3 C3: same mechanism, separate routing. Merging the queues
# would bury the rare important decision under the frequent cheap one.
RSpec.describe "Decision queues" do
  let(:repo) { Factories.repository }

  def decision!(queue:, urgency: "normal", created_at: Time.current)
    Decision.create!(
      problem_code: "grader_failure", signature: SecureRandom.hex(4), title: "t",
      repository: repo, queue: queue, urgency: urgency, created_at: created_at
    )
  end

  it "routes the two queues separately" do
    operator = decision!(queue: "operator")
    triage = decision!(queue: "triage")

    expect(Decision.operator_queue).to contain_exactly(operator)
    expect(Decision.triage_queue).to contain_exactly(triage)
  end

  it "orders a queue by urgency, then age" do
    old_normal = decision!(queue: "operator", created_at: 2.days.ago)
    low = decision!(queue: "operator", urgency: "low")
    urgent = decision!(queue: "operator", urgency: "urgent")

    expect(Decision.operator_queue.in_attention_order.to_a).to eq([ urgent, old_normal, low ])
  end

  it "summarizes one queue without counting the other" do
    decision!(queue: "operator", urgency: "urgent")
    decision!(queue: "triage")

    expect(Decision.queue_summary("operator")).to eq(queue: "operator", open: 1, by_urgency: { "urgent" => 1 })
  end

  it "leaves decided and expired work out of a queue summary" do
    decided = decision!(queue: "operator")
    decided.decide!(resolution: "dismissed")
    decision!(queue: "operator").update!(expires_at: 1.hour.ago)

    expect(Decision.queue_summary("operator")[:open]).to eq(0)
  end
end
