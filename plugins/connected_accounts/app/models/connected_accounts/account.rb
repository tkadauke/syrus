module ConnectedAccounts
  class Account < Syrus::Host::Record
    self.table_name = "connected_accounts_accounts"

    STATUSES = %w[connected needs_reauth revoked error].freeze
    ACTING_MODES = %w[as_owner as_self as_service].freeze
    OWNER_KINDS = %w[user instance].freeze

    belongs_to :owner_user, class_name: "::User", optional: true
    belongs_to :credential_store_credential, class_name: "CredentialStore::Credential"

    attribute :granted_scopes, :json, default: -> { [] }
    attribute :scope_ceiling, :json
    attribute :acting_modes, :json, default: -> { [] }
    attribute :owner_kind, :string, default: "user"

    enum :status, STATUSES.index_with(&:itself), validate: true
    enum :owner_kind, OWNER_KINDS.index_with(&:itself), validate: true

    scope :retention_candidates, -> { where(status: %w[revoked error]) }

    validates :provider, :display_label, presence: true
    validates :read_only, inclusion: { in: [ true, false ] }
    validate :validate_string_arrays
    validate :validate_acting_modes
    validate :validate_credential_contract
    validate :validate_owner_contract

    before_validation :normalize_values

    def last_used_at
      CredentialStore::CredentialAccessEvent.where(
        credential_id: credential_store_credential_id, action: "lease", result: "allowed"
      ).maximum(:created_at)
    end

    def acting_mode_enabled?(mode)
      mode = mode.to_s
      return ProviderConfig.where(provider_key: provider, allow_as_owner: true).exists? if mode == "as_owner"

      acting_modes.include?(mode)
    end

    def visible_to?(user)
      owner_policy.visible_to?(self, user)
    end

    def owner_policy = AccountOwnerKind::Base.for(owner_kind)

    def effective_scope_ceiling
      return scope_ceiling if scope_ceiling.present?

      read_only? ? granted_scopes.grep(/(?:read|readonly)\z/) : granted_scopes
    end

    private

    def normalize_values
      self.provider = provider.to_s.strip.downcase.presence
      self.display_label = display_label.to_s.strip.presence
      self.granted_scopes = Array(granted_scopes).filter_map { |scope| scope.to_s.strip.presence }.uniq.sort
      self.scope_ceiling = Array(scope_ceiling).filter_map { |scope| scope.to_s.strip.presence }.uniq.sort if scope_ceiling
      self.acting_modes = Array(acting_modes).filter_map { |mode| mode.to_s.strip.presence }.uniq.sort
    end

    def validate_string_arrays
      errors.add(:granted_scopes, I18n.t("connected_accounts.errors.array_of_strings")) unless granted_scopes.is_a?(Array) && granted_scopes.all?(String)
      errors.add(:acting_modes, I18n.t("connected_accounts.errors.array_of_strings")) unless acting_modes.is_a?(Array) && acting_modes.all?(String)
      errors.add(:scope_ceiling, I18n.t("connected_accounts.errors.array_of_strings")) unless scope_ceiling.nil? || (scope_ceiling.is_a?(Array) && scope_ceiling.all?(String))
      errors.add(:scope_ceiling, I18n.t("connected_accounts.errors.scope_ceiling_subset")) if scope_ceiling.present? && (scope_ceiling - granted_scopes).any?
    end

    def validate_acting_modes
      invalid = acting_modes - ACTING_MODES
      errors.add(:acting_modes, I18n.t("connected_accounts.errors.unsupported_modes", modes: invalid.join(", "))) if invalid.any?
    end

    def validate_credential_contract
      return unless credential_store_credential

      if credential_store_credential.credential_type != AccountClient::CREDENTIAL_TYPE
        errors.add(:credential_store_credential, I18n.t("connected_accounts.errors.oauth_material"))
      end
      owner_policy.validate_credential(self, credential_store_credential)
      unless credential_store_credential.allowed_tools == [ AccountClient::BROKER_TOOL_NAME ]
        errors.add(:credential_store_credential, I18n.t("connected_accounts.errors.broker_pinned"))
      end
      if Array(credential_store_credential.target_constraints["allowed_url_prefixes"]).empty?
        errors.add(:credential_store_credential, I18n.t("connected_accounts.errors.origins_pinned"))
      end
    end


    def validate_owner_contract
      owner_policy.validate_account(self)
    end
  end
end
