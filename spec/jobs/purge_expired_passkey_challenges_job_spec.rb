require "rails_helper"

RSpec.describe PurgeExpiredPasskeyChallengesJob do
  it "deletes expired challenges and keeps unexpired ones" do
    expired = PasskeyChallenge.create!(
      challenge: SecureRandom.urlsafe_base64(32),
      challenge_type: "registration",
      expires_at: 1.minute.ago
    )
    unexpired = PasskeyChallenge.create!(
      challenge: SecureRandom.urlsafe_base64(32),
      challenge_type: "authentication",
      expires_at: 5.minutes.from_now
    )

    described_class.perform_now

    expect(PasskeyChallenge.where(id: expired.id)).to be_empty
    expect(PasskeyChallenge.where(id: unexpired.id)).to contain_exactly(unexpired)
  end

  it "does nothing when there are no expired challenges" do
    PasskeyChallenge.create!(
      challenge: SecureRandom.urlsafe_base64(32),
      challenge_type: "registration",
      expires_at: 5.minutes.from_now
    )

    expect { described_class.perform_now }.not_to change(PasskeyChallenge, :count)
  end
end
