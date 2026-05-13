require "rails_helper"

RSpec.describe Prompts::OperatorClarificationInstructions do
  it "documents when ask_operator is appropriate and the disabled fallback" do
    text = described_class::TEXT

    expect(text).to include("ask_operator(question:, context:)")
    expect(text).to include("materially affects design")
    expect(text).to include("Style preferences")
    expect(text).to include("needs_clarification")
  end
end
