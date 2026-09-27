require "rails_helper"

RSpec.describe "GitHub-sourced prompt trust boundaries" do
  REQUIRED_PROMPTS = %w[
    app/services/prompts/implement.rb
    app/services/prompts/pr_feedback.rb
  ].freeze

  it "marks prompt templates that render issue or PR comment content" do
    missing = REQUIRED_PROMPTS.reject do |relative|
      Rails.root.join(relative).read.include?(Prompts::GithubContentTrust::MARKER)
    end

    expect(missing).to be_empty
  end
end
