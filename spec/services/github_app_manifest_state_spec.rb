require "rails_helper"

RSpec.describe GithubAppManifestState do
  let(:user) { Factories.user }

  describe ".generate" do
    it "returns a non-empty signed token string" do
      token = described_class.generate(user: user)

      expect(token).to be_a(String)
      expect(token).not_to be_empty
    end

    it "embeds the user id and a nonce in the verifiable payload" do
      token = described_class.generate(user: user)
      payload = described_class.verify(token)

      expect(payload).not_to be_nil
      expect(payload.user_id).to eq(user.id)
      expect(payload.nonce).not_to be_blank
    end

    it "includes an optional origin in the payload" do
      token = described_class.generate(user: user, origin: "desktop")
      payload = described_class.verify(token)

      expect(payload.origin).to eq("desktop")
    end

    it "omits origin when not given" do
      token = described_class.generate(user: user)
      payload = described_class.verify(token)

      expect(payload.origin).to be_nil
    end

    it "generates distinct nonces on each call" do
      t1 = described_class.generate(user: user)
      t2 = described_class.generate(user: user)

      p1 = described_class.verify(t1)
      p2 = described_class.verify(t2)

      expect(p1.nonce).not_to eq(p2.nonce)
    end
  end

  describe ".verify" do
    it "returns nil for a forged / empty token" do
      expect(described_class.verify("not-a-real-token")).to be_nil
      expect(described_class.verify("")).to be_nil
      expect(described_class.verify(nil)).to be_nil
    end

    it "returns nil for an expired token" do
      token = travel_to(20.minutes.ago) { described_class.generate(user: user) }

      expect(described_class.verify(token)).to be_nil
    end

    it "returns a Payload for a fresh, valid token" do
      token = described_class.generate(user: user)
      payload = described_class.verify(token)

      expect(payload).to be_a(GithubAppManifestState::Payload)
    end
  end

  describe ".consume!" do
    it "returns true (cache write succeeds) on first call" do
      token = described_class.generate(user: user)
      payload = described_class.verify(token)

      result = described_class.consume!(payload.nonce)

      expect(result).to be_truthy
    end

    it "blocks a replay with the same nonce when backed by a real cache store" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      token = described_class.generate(user: user)
      payload = described_class.verify(token)

      first = described_class.consume!(payload.nonce)
      second = described_class.consume!(payload.nonce)

      expect(first).to be_truthy
      expect(second).to be_falsy
    end
  end
end
