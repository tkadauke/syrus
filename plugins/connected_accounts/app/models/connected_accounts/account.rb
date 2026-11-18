module ConnectedAccounts
  class Account < ApplicationRecord
    self.table_name = "connected_accounts_accounts"

    STATUSES = %w[connected needs_reauth revoked error].freeze
    ACTING_MODES = %w[as_owner as_self as_service].freeze

    belongs_to :owner_user, class_name: "::User"
    belongs_to :credential,
      class_name: "CredentialStore::Credential",
      foreign_key: :credential_store_credential_id,
      inverse_of: false

    attribute :granted_scopes, :json, default: -> { [] }
    attribute :access_ceiling, :json, default: -> { [] }
    attribute :acting_modes, :json, default: -> { [] }

    enum :status, STATUSES.index_with(&:itself), validate: true

    validates :provider_key, presence: true, format: { with: /\A[a-z][a-z0-9_.-]*\z/ }
    validates :display_label, presence: true, length: { maximum: 255 }
    validates :credential_store_credential_id, uniqueness: true
    validate :scope_lists_are_valid
    validate :acting_modes_are_valid
    validate :credential_contract

    before_validation :normalize_arrays

    def permits_scopes?(requested_scopes)
      requested = normalize_list(requested_scopes)
      requested.difference(granted_scopes).empty? && requested.difference(effective_ceiling).empty?
    end

    def permits_acting_mode?(acting_mode)
      acting_modes.include?(acting_mode.to_s)
    end

    def effective_ceiling
      access_ceiling.presence || granted_scopes
    end

    private

    def normalize_arrays
      self.granted_scopes = normalize_list(granted_scopes)
      self.access_ceiling = normalize_list(access_ceiling)
      self.acting_modes = normalize_list(acting_modes)
    end

    def normalize_list(value)
      Array(value).filter_map { |item| item.to_s.strip.presence }.uniq.sort
    end

    def scope_lists_are_valid
      unless granted_scopes.is_a?(Array) && access_ceiling.is_a?(Array)
        errors.add(:granted_scopes, "and access ceiling must be arrays")
        return
      end

      outside_grant = access_ceiling.difference(granted_scopes)
      errors.add(:access_ceiling, "must be a subset of granted scopes") if outside_grant.any?
    end

    def acting_modes_are_valid
      return errors.add(:acting_modes, "must be an array") unless acting_modes.is_a?(Array)

      invalid = acting_modes.difference(ACTING_MODES)
      errors.add(:acting_modes, "contains unsupported modes: #{invalid.join(', ')}") if invalid.any?
    end

    def credential_contract
      return unless credential

      errors.add(:credential, "must use connected_accounts.oauth") unless credential.credential_type == "connected_accounts.oauth"
      errors.add(:credential, "must belong to the account owner") unless credential.owner_user_id == owner_user_id
      allowed_tools = Array(credential.allowed_tools)
      errors.add(:credential, "must be pinned to the account broker") unless allowed_tools == [ AccountClient::BROKER_TOOL_NAME ]
      origins = Array(credential.target_constraints.to_h["allowed_url_prefixes"])
      errors.add(:credential, "must declare provider API origins") if origins.empty?
    end
  end
end
