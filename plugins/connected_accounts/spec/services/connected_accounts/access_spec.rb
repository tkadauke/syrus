require "rails_helper"

RSpec.describe ConnectedAccounts::Access do
  subject(:access) { described_class.new("super-secret-token") }

  it "hands the raw token only to the block and returns the block's value" do
    seen = nil
    result = access.with_token { |token| seen = token; token.length }

    expect(seen).to eq("super-secret-token")
    expect(result).to eq("super-secret-token".length)
  end

  it "never renders the token" do
    expect([ access.to_s, access.inspect, access.to_json ].join).not_to include("super-secret-token")
  end
end
