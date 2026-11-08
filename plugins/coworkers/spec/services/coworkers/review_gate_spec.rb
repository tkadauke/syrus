require "rails_helper"

RSpec.describe Coworkers::ReviewGate do
  it "is registered as a review gate ordered between security and visual review" do
    definition = Workflows::ReviewGateRegistry.definitions.find { |item| item.key == "coworker" }

    expect(definition).to have_attributes(
      step_kind: "coworker_review", after: %w[security], before: %w[visual],
      verdict_artifact: "coworker_review_iterations", panel_capable: true
    )
    expect(Workflows::ReviewGateRegistry.ordered("after_agent").map(&:step_kind).last(3))
      .to eq(%w[security_review coworker_review visual_review])
  end

  it "declares the coworker_review step kind from the plugin" do
    expect(Coworkers::WorkflowKinds.step_kinds.map { |kind| kind[:kind] }).to include("coworker_review")
    expect(Step::Kind.fetch("coworker_review")).to have_attributes(
      reviewer_target_required: true, panel_capable: true, required_mcp_tools: %w[submit_coworker_review]
    )
    expect(Step::Kind.review_gate_for("coworker_review")).to include(
      artifact_key: "coworker_review_iterations", exit_verdicts: %w[approved skipped]
    )
  end
end
