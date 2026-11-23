# A native client (currently the iOS app) that can receive push notifications
# for one user. The row is keyed by the platform's device token, not by user:
# a token identifies one app install, so registering it again from a different
# signed-in user moves it rather than creating a second row.
class PushDevice < ApplicationRecord
  PLATFORMS = %w[ios].freeze
  ENVIRONMENTS = %w[sandbox production].freeze
  # APNs device tokens are hex strings (currently 64 characters, documented as
  # variable length), so accept a generous hex-only range.
  TOKEN_FORMAT = /\A[0-9a-fA-F]{32,190}\z/

  belongs_to :user
  # The browser session the registration was made from. Signing out destroys
  # the session, and with it the device, so a signed-out phone stops receiving
  # that user's notifications.
  belongs_to :session, optional: true

  before_validation :normalize_token

  validates :platform, inclusion: { in: PLATFORMS }
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :token, presence: true, format: { with: TOKEN_FORMAT }, uniqueness: { scope: :platform }
  validates :last_registered_at, presence: true

  scope :active, -> { where(disabled_at: nil) }
  scope :ios, -> { where(platform: "ios") }

  # Idempotent upsert used by the registration endpoint. Re-registering a
  # disabled token re-enables it; registering under a different user or
  # session re-associates it.
  def self.register!(user:, token:, session: nil, platform: "ios", environment: "production", **attributes)
    normalized = token.to_s.strip.downcase
    device = find_or_initialize_by(platform: platform, token: normalized)
    device.assign_attributes(
      attributes.slice(:bundle_id, :device_name, :app_version).merge(
        user: user,
        session: session,
        environment: environment,
        last_registered_at: Time.current,
        disabled_at: nil,
        disabled_reason: nil
      )
    )
    device.save!
    device
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def disable!(reason:)
    update!(disabled_at: Time.current, disabled_reason: reason.to_s)
  end

  def active? = disabled_at.nil?

  private

  def normalize_token
    self.token = token.to_s.strip.downcase.presence
  end
end
