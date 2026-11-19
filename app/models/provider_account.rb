class ProviderAccount < ApplicationRecord
  # Transitional import only. Remove this entry point together with the
  # provider credential columns once every credential consumer accepts an
  # account explicitly.
  def self.sync_legacy_defaults_for!(user)
    User.agent_providers.each do |provider_key|
      provider = AgentProviders.for(provider_key)
      attributes = provider.credential_attributes
      payload = attributes.index_with { |attribute| user.public_send(attribute) }.compact
      account = user.provider_accounts.find_by(provider_key: provider_key, position: 0)

      unless provider.configured_for_user?(user)
        account&.destroy!
        next
      end

      authentication_kind = payload["codex_auth_mode"] || payload[:codex_auth_mode]
      authentication_kind ||= attributes.find { |attribute| payload[attribute].present? }.to_s
      account ||= user.provider_accounts.build(provider_key: provider_key, position: 0)
      account.assign_attributes(
        authentication_kind: authentication_kind,
        credential_payload: payload.stringify_keys,
        enabled: true
      )
      account.save!
    end
  end

  belongs_to :user

  encrypts :credential_payload
  serialize :credential_payload, coder: JSON

  before_validation :assign_public_id, on: :create

  scope :enabled, -> { where(enabled: true) }
  scope :in_position_order, -> { order(:position, :id) }

  validates :public_id, presence: true, uniqueness: true
  validates :provider_key, presence: true, length: { maximum: 64 }
  validates :authentication_kind, presence: true, length: { maximum: 64 }
  validates :label, length: { maximum: 100 }, allow_nil: true
  validates :label, uniqueness: { scope: %i[user_id provider_key], case_sensitive: false }, allow_nil: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :position, uniqueness: { scope: %i[user_id provider_key] }
  validates :weight, numericality: { greater_than: 0 }, allow_nil: true
  validate :provider_is_registered
  validate :credential_payload_is_an_object

  def default? = position.zero?

  def credential(name) = credential_payload.to_h[name.to_s]

  def safe_reference
    { id: public_id, label: label.presence || "Account #{position + 1}" }
  end

  private

  def assign_public_id
    self.public_id ||= SecureRandom.uuid
  end

  def provider_is_registered
    return if provider_key.blank? || provider_key.in?(User.agent_providers)

    errors.add(:provider_key, "is not a registered agent provider")
  end

  def credential_payload_is_an_object
    return if credential_payload.is_a?(Hash)

    errors.add(:credential_payload, "must be an object")
  end
end
