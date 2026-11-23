# An APNs (or future platform) push destination owned by a user.
class PushDevice < ApplicationRecord
  PLATFORMS = %w[ios].freeze
  ENVIRONMENTS = %w[sandbox production].freeze
  TOKEN_FORMAT = /\A[0-9a-f]{32,160}\z/i

  belongs_to :user
  belongs_to :session, optional: true

  validates :platform, inclusion: { in: PLATFORMS }
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :token, presence: true, format: { with: TOKEN_FORMAT }, uniqueness: { scope: :platform }

  scope :active, -> { where(disabled_at: nil) }

  def disable!(reason)
    update!(disabled_at: Time.current, disabled_reason: reason)
  end
end
