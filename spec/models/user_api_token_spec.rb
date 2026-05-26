require "rails_helper"

RSpec.describe User, "API token" do
  let(:user) { Factories.user }

  describe "#generate_api_token!" do
    it "returns a fresh token with the syrus_ prefix" do
      token = user.generate_api_token!
      expect(token).to start_with("syrus_")
      # 32 url-safe base64 bytes ≈ 43 chars + the "syrus_" prefix.
      expect(token.length).to be >= 40
    end

    it "persists the token (deterministic-encrypted) so we can WHERE on it" do
      token = user.generate_api_token!
      expect(User.find_by(api_token: token)).to eq(user)
    end

    it "keeps a unique index for deterministic encrypted lookup" do
      index = User.connection.indexes(:users).find { |candidate| candidate.name == "index_users_on_api_token" }

      expect(index).to be_present
      expect(index.columns).to eq([ "api_token" ])
      expect(index.unique).to be(true)
    end

    it "rotates — a new call invalidates the prior token" do
      first = user.generate_api_token!
      second = user.generate_api_token!
      expect(second).not_to eq(first)
      expect(User.find_by(api_token: first)).to be_nil
      expect(User.find_by(api_token: second)).to eq(user)
    end
  end

  describe "#revoke_api_token!" do
    it "clears the token" do
      token = user.generate_api_token!
      user.revoke_api_token!
      expect(user.reload.api_token).to be_nil
      expect(User.find_by(api_token: token)).to be_nil
    end
  end
end
