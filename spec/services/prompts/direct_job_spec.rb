require "rails_helper"

RSpec.describe Prompts::DirectJob do
  describe "#to_s" do
    it "includes the operator's prompt text" do
      out = described_class.new(prompt: "Fix the flaky login spec.").to_s
      expect(out).to include("Fix the flaky login spec.")
    end

    it "strips leading and trailing whitespace from the prompt" do
      out = described_class.new(prompt: "   some prompt   ").to_s
      expect(out).to start_with("some prompt")
    end

    it "appends the git safety block" do
      out = described_class.new(prompt: "Do something.").to_s
      expect(out).to include(Prompts::GitSafety::TEXT)
    end

    it "appends the submit-summary instructions" do
      out = described_class.new(prompt: "Do something.").to_s
      expect(out).to include(Prompts::SubmitSummaryInstructions::TEXT)
    end

    it "places the prompt before the git safety block" do
      out = described_class.new(prompt: "My task.").to_s
      prompt_pos = out.index("My task.")
      safety_pos = out.index(Prompts::GitSafety::TEXT)
      expect(prompt_pos).to be < safety_pos
    end

    it "places the git safety block before submit-summary instructions" do
      out = described_class.new(prompt: "My task.").to_s
      safety_pos  = out.index(Prompts::GitSafety::TEXT)
      summary_pos = out.index(Prompts::SubmitSummaryInstructions::TEXT)
      expect(safety_pos).to be < summary_pos
    end

    context "when the prompt is a skill invocation" do
      it "passes the skill slash-command through unchanged" do
        out = described_class.new(prompt: "/configure-syrus-prep").to_s
        expect(out).to start_with("/configure-syrus-prep")
      end

      it "still appends git safety and submit-summary so the agent commits and summarizes" do
        out = described_class.new(prompt: "/configure-syrus-prep").to_s
        expect(out).to include(Prompts::GitSafety::TEXT)
        expect(out).to include(Prompts::SubmitSummaryInstructions::TEXT)
      end
    end
  end
end
