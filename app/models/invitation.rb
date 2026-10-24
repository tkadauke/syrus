class Invitation < ApplicationRecord
  DEFAULT_TTL = 7.days

  belongs_to :invited_by, class_name: "User"

  has_secure_token :token

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :expires_at, presence: true
  validates :locale, presence: true, inclusion: { in: User::LOCALES }

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  before_validation :set_default_expiry, on: :create
  before_validation :set_default_locale, on: :create

  def accept!
    update!(accepted_at: Time.current)
  end

  def accepted?
    accepted_at.present?
  end

  def expired?
    expires_at <= Time.current
  end

  def usable?
    !accepted? && !expired?
  end

  private

  def set_default_expiry
    self.expires_at ||= DEFAULT_TTL.from_now
  end

  def set_default_locale
    return if locale.present?

    default_locale = invited_by&.locale.presence || I18n.default_locale.to_s
    self.locale = User::LOCALES.include?(default_locale) ? default_locale : User::LOCALES.first
  end
end
