require "rails_helper"

# workflow-engine-v3 A3: "StepDispatcher no longer names any specific reviewer
# step kind." The dispatcher used to carry one hardcoded copy of the
# reviewer-loop exit logic per reviewer -- same method, three constants swapped
# -- so a third reviewer cost a third copy.
RSpec.describe "Reviewer loops are declared, not hardcoded" do
  it "declares a review gate on every reviewer step kind" do
    expect(Step::Kind.review_gate_kinds).to contain_exactly("adversarial_review", "visual_review")
  end

  it "declares the artifact, exit verdicts and cancellation reason for each" do
    Step::Kind.review_gate_kinds.each do |kind|
      gate = Step::Kind.review_gate_for(kind)

      expect(gate[:artifact_key]).to be_present, "#{kind} declares no artifact_key"
      expect(gate[:exit_verdicts]).to be_present, "#{kind} declares no exit_verdicts"
      expect(gate[:cancellation_reason]).to be_present, "#{kind} declares no cancellation_reason"
    end
  end

  # "skipped" means not visually testable, which exits the loop the same way
  # "approved" does -- there is nothing for another iteration to address.
  it "lets visual review exit on skipped as well as approved" do
    expect(Step::Kind.review_gate_for("visual_review")[:exit_verdicts]).to contain_exactly("approved", "skipped")
    expect(Step::Kind.review_gate_for("adversarial_review")[:exit_verdicts]).to contain_exactly("approved")
  end

  it "returns no gate for a step kind that is not a reviewer" do
    expect(Step::Kind.review_gate_for("implement")).to be_nil
    expect(Step::Kind.review_gate_for("not_a_step_kind")).to be_nil
  end

  it "does not name a reviewer step kind anywhere in StepDispatcher" do
    source = Rails.root.join("app/services/step_dispatcher.rb").read
    code = source.lines.reject { |line| line.strip.start_with?("#") }.join

    Step::Kind.review_gate_kinds.each do |kind|
      expect(code).not_to include(kind), "StepDispatcher still names #{kind}"
    end
  end
end
