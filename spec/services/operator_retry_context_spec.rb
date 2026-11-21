require "rails_helper"

RSpec.describe OperatorRetryContext do
  let(:workflow) { Factories.job.latest_workflow }

  it "appends guidance after any existing operator context" do
    workflow.set_artifact!("replay_context", "Earlier context.")

    described_class.append!(workflow, "Fix the host surface.", at: Time.utc(2026, 11, 21, 15))

    expect(workflow.reload.artifact("replay_context")).to eq(
      "Earlier context.\n\nOperator guidance (2026-11-21T15:00:00Z):\nFix the host surface."
    )
  end

  it "keeps the guidance when the retry starts and restores the context when it does not" do
    started = Struct.new(:success?).new(true)
    refused = Struct.new(:success?).new(false)

    described_class.with_context(workflow, "kept") { started }
    expect(workflow.reload.artifact("replay_context")).to include("kept")

    described_class.with_context(workflow, "dropped") { refused }
    expect(workflow.reload.artifact("replay_context")).to include("kept")
    expect(workflow.artifact("replay_context")).not_to include("dropped")
  end

  it "leaves the context untouched for blank guidance" do
    described_class.with_context(workflow, "  ") { :anything }

    expect(workflow.reload.artifact("replay_context")).to be_nil
  end
end
