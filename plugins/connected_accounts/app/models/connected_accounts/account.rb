module ConnectedAccounts
  class Account < ApplicationRecord
    self.table_name = "connected_accounts"

    STATUSES = %w[connected needs_reauth revoked error].freeze
    ACTING_MODES = %w[as_owner as_self as_service].freeze

    belongs_to :owner_user, class_name: "::User"
    belongs_to :credential, class_name: "CredentialStore::Credential",
      foreign_key: :credential_store_credential_id

    attribute :granted_scopes, :json, default: -> { [] }
    attribute :scope_ceiling, :json, default: -> { [] }
    attribute :acting_modes, :json, default: -> { [] }

    validates :provider_key, presence: true, format: { with: /\A[a-z][a-z0-9_.-]*\z/ }
    validates :display_label, presence: true, length: { maximum: 255 }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :scope_arrays_are_valid
    validate :acting_modes_are_valid
    validate :credential_contract_is_valid

    before_validation :normalize_values

    def connected? = status == "connected"

    def permits_scopes?(requested)
      normalized = normalize_array(requested)
      normalized.all? { |scope| granted_scopes.include?(scope) } &&
        (scope_ceiling.empty? || normalized.all? { |scope| scope_ceiling.include?(scope) })
    end

    def permits_acting_mode?(mode) = acting_modes.include?(mode.to_s)

    private

    def normalize_values
      self.provider_key = provider_key.to_s.strip.downcase.presence
      self.display_label = display_label.to_s.strip.presence
      self.status = status.to_s.strip.downcase.presence
      self.granted_scopes = normalize_array(granted_scopes)
      self.scope_ceiling = normalize_array(scope_ceiling)
      self.acting_modes = normalize_array(acting_modes)
    end

    def normalize_array(value)
      Array(value).filter_map { |item| item.to_s.strip.presence }.uniq
    end

    def scope_arrays_are_valid
      errors.add(:granted_scopes, "must be an array") unless granted_scopes.is_a?(Array)
      errors.add(:scope_ceiling, "must be an array") unless scope_ceiling.is_a?(Array)
      return unless granted_scopes.is_a?(Array) && scope_ceiling.is_a?(Array)

      errors.add(:scope_ceiling, "must be a subset of granted scopes") if (scope_ceiling - granted_scopes).any?
    end

    def acting_modes_are_valid
      errors.add(:acting_modes, "must be an array") unless acting_modes.is_a?(Array)
      return unless acting_modes.is_a?(Array)

      errors.add(:acting_modes, "contains unsupported modes") if (acting_modes - ACTING_MODES).any?
    end

    def credential_contract_is_valid
      return unless credential

      errors.add(:credential, "must be a Connected Accounts OAuth credential") unless credential.credential_type == AccountClient::CREDENTIAL_TYPE
      errors.add(:credential, "must have the same owner") unless credential.owner_user_id == owner_user_id
      unless Array(credential.allowed_tools) == [ AccountClient::TOOL_NAME ]
        errors.add(:credential, "must be pinned to AccountClient")
      end
      unless credential.target_constraints.to_h["allowed_url_prefixes"].is_a?(Array) && credential.target_constraints["allowed_url_prefixes"].any?
        errors.add(:credential, "must constrain provider API origins")
      end
    end
  end
end
