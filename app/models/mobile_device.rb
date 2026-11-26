# A native mobile app installation that can receive push notifications for a
# user. Today only iOS (APNs) is supported; `platform` leaves room for others.
#
# Rows are keyed by (platform, token): the same physical token re-registering
# under a different user (shared device, sign-out/sign-in) moves ownership
# rather than duplicating, so a token never receives another user's pushes.
class MobileDevice < ApplicationRecord
  PLATFORMS = %w[ios].freeze
  APNS_ENVIRONMENTS = %w[sandbox production].freeze

  belongs_to :user
  belongs_to :session, optional: true

  validates :platform, inclusion: { in: PLATFORMS }
  validates :apns_environment, inclusion: { in: APNS_ENVIRONMENTS }
  validates :token, presence: true, length: { maximum: 191 },
                    format: { with: /\A[0-9a-fA-F]+\z/, message: ->(*) { I18n.t("models.mobile_device.errors.token_format") } }
  validates :bundle_id, presence: true
  validates :last_registered_at, presence: true

  scope :active, -> { where(disabled_at: nil) }

  # Registers (or re-registers) a device token for `user`, re-enabling it if
  # APNs previously rejected it. Idempotent.
  def self.register!(user:, session:, attributes:)
    device = find_or_initialize_by(platform: attributes.fetch(:platform, "ios"), token: attributes.fetch(:token).to_s.downcase)
    device.assign_attributes(
      attributes.except(:platform, :token).merge(
        user: user,
        session: session,
        last_registered_at: Time.current,
        disabled_at: nil,
        disabled_reason: nil
      )
    )
    device.save!
    device
  end

  def disable!(reason)
    update!(disabled_at: Time.current, disabled_reason: reason.to_s.truncate(255))
  end
end
