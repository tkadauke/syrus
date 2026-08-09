require "rails_helper"

RSpec.describe PasskeyChallenge do
  let(:user) { Factories.user }

  describe ".valid scope" do
    it "includes challenges that have not expired" do
      fresh = described_class.create!(
        challenge: SecureRandom.urlsafe_base64(32),
        challenge_type: "registration",
        expires_at: 5.minutes.from_now
      )

      expect(described_class.valid).to include(fresh)
    end

    it "excludes challenges that have expired" do
      expired = described_class.create!(
        challenge: SecureRandom.urlsafe_base64(32),
        challenge_type: "registration",
        expires_at: 1.second.ago
      )

      expect(described_class.valid).not_to include(expired)
    end
  end

  describe ".for_type scope" do
    it "filters by challenge_type" do
      registration = described_class.create!(
        challenge: SecureRandom.urlsafe_base64(32),
        challenge_type: "registration",
        expires_at: 5.minutes.from_now
      )
      authentication = described_class.create!(
        challenge: SecureRandom.urlsafe_base64(32),
        challenge_type: "authentication",
        expires_at: 5.minutes.from_now
      )

      expect(described_class.for_type("registration")).to include(registration)
      expect(described_class.for_type("registration")).not_to include(authentication)
    end
  end

  describe ".create_for!" do
    it "creates a challenge with the correct TTL" do
      freeze_time do
        challenge = described_class.create_for!(
          type: "registration",
          challenge: SecureRandom.urlsafe_base64(32)
        )

        expect(challenge.expires_at).to be_within(1.second).of(5.minutes.from_now)
        expect(challenge.challenge_type).to eq("registration")
        expect(challenge.user).to be_nil
      end
    end

    it "respects a custom TTL" do
      freeze_time do
        challenge = described_class.create_for!(
          type: "authentication",
          challenge: SecureRandom.urlsafe_base64(32),
          ttl: 10.minutes
        )

        expect(challenge.expires_at).to be_within(1.second).of(10.minutes.from_now)
      end
    end

    it "associates a user when provided" do
      challenge = described_class.create_for!(
        type: "registration",
        challenge: SecureRandom.urlsafe_base64(32),
        user: user
      )

      expect(challenge.user).to eq(user)
    end
  end
end
