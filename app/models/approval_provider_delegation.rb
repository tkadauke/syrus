class ApprovalProviderDelegation < ApplicationRecord
  CORE_HUMAN_ONLY_EFFECTS = %w[financial privilege_change].freeze

  belongs_to :owner_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true

  attribute :resource_scope, :json, default: -> { {} }
  attribute :excluded_effects, :json, default: -> { [] }

  validates :provider_key, :capability, :resource_type, presence: true
  validate :validate_json_shapes
  validate :validate_revocation_attribution

  before_validation :canonicalize_json

  scope :active, -> { where(revoked_at: nil) }

  def covers?(invocation)
    active? && capability == invocation.capability && resource_type == invocation.resource_type &&
      scope_covers?(resource_scope, invocation.resource_scope) &&
      (excluded_effects & invocation.effects).empty?
  end

  def active? = revoked_at.nil?

  def revoke!(actor:, at: Time.current)
    with_lock do
      return self if revoked_at?

      update!(revoked_at: at, revoked_by_user: actor)
    end
    self
  end

  private

  def canonicalize_json
    self.resource_scope = canonical(resource_scope) if resource_scope.is_a?(Hash)
    self.excluded_effects = (Array(excluded_effects).map(&:to_s) + CORE_HUMAN_ONLY_EFFECTS).uniq.sort
  end

  def canonical(value)
    case value
    when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
    when Array then value.map { |item| canonical(item) }
    when Symbol then value.to_s
    else value
    end
  end

  def scope_covers?(ceiling, requested)
    ceiling.all? do |key, expected|
      next false unless requested.key?(key)

      actual = requested[key]
      if expected.is_a?(Array)
        actual.is_a?(Array) && actual.any? && actual.all? { |item| expected.include?(item) }
      else
        actual == expected
      end
    end
  end

  def validate_json_shapes
    errors.add(:resource_scope, "must be a JSON object") unless resource_scope.is_a?(Hash)
    errors.add(:excluded_effects, "must be a JSON array") unless excluded_effects.is_a?(Array)
  end

  def validate_revocation_attribution
    return if revoked_at.present? == revoked_by_user_id.present?

    errors.add(:revoked_by_user, "must be present exactly when the delegation is revoked")
  end
end
