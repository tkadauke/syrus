require "rails_helper"

RSpec.describe Prompts::TestPlan do
  it "tells the agent to call submit_test_plan with steps and notes" do
    text = described_class.new.to_s

    expect(text).to include("submit_test_plan")
    expect(text).to include("steps")
    expect(text).to include("notes")
    expect(text).to include("Don't make")
  end
end
