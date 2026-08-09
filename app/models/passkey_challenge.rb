class PasskeyChallenge < ApplicationRecord
  belongs_to :user, optional: true

  scope :valid, -> { where("expires_at > ?", Time.current) }
  scope :for_type, ->(type) { where(challenge_type: type) }

  def self.create_for!(type:, challenge:, user: nil, ttl: 5.minutes)
    create!(
      challenge_type: type,
      challenge: challenge,
      user: user,
      expires_at: ttl.from_now
    )
  end
end
