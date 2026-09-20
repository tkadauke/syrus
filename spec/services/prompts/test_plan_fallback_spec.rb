require "rails_helper"

RSpec.describe Prompts::TestPlanFallback do
  it "uses repository-agnostic reviewer examples" do
    issue = Struct.new(:title, :body).new("Fix the thing", "Details")
    text = described_class.new(issue: issue, summary: "Changed behavior.", diff: "").to_s

    expect(text).to include("repository's focused test")
    expect(text).to include("affected screen")
    expect(text).not_to include("bin/rspec")
    expect(text).not_to include("/jobs/123")
  end
end
