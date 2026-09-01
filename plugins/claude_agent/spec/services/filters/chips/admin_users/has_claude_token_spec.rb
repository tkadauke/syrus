require "rails_helper"

RSpec.describe Filters::Chips::AdminUsers::HasClaudeToken do
  let!(:with_token) { Factories.user(claude_oauth_token: "oat-secret") }
  let!(:without_token) { Factories.user(claude_oauth_token: nil) }

  it "filters users with a Claude token" do
    result = described_class.new(scope: User.all, op: :is, value: "true", user: with_token).apply

    expect(result).to include(with_token)
    expect(result).not_to include(without_token)
  end

  it "filters users without a Claude token" do
    result = described_class.new(scope: User.all, op: :is, value: "false", user: with_token).apply

    expect(result).to include(without_token)
    expect(result).not_to include(with_token)
  end
end
