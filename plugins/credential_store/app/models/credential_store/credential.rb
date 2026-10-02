module CredentialStore
  class Credential < ApplicationRecord
    self.table_name = "credential_store_credentials"

    TYPE_NAME_PATTERN = Syrus::PluginRegistry.credential_type_name_pattern
    NAME_MAX_LENGTH = 120
    DESCRIPTION_MAX_LENGTH = 1000
    SAFE_METADATA_MAX_BYTES = 8.kilobytes
    TARGET_CONSTRAINTS_MAX_BYTES = 8.kilobytes
    ALLOWED_VALUE_PATTERN = /\A[a-z][a-z0-9_.:-]*\z/
    ALLOWED_SCOPES = %w[user repository team instance].freeze
    SAFE_METADATA_KEYS = %w[
      base_url
      cluster
      context
      fingerprint
      host
      known_host
      namespace
      port
      username
    ].freeze
    TARGET_CONSTRAINT_KEYS = %w[
      allowed_hosts
      allowed_kube_clusters
      allowed_kube_contexts
      allowed_kube_namespaces
      allowed_url_prefixes
    ].freeze
    SECRET_KEY_PATTERN = /(?:secret|token|password|passphrase|private[_-]?key|client[_-]?key|credential|auth)/i

    belongs_to :created_by, class_name: "::User"
    belongs_to :owner_user, class_name: "::User", optional: true
    has_many :access_events,
      class_name: "CredentialStore::CredentialAccessEvent",
      foreign_key: :credential_id,
      inverse_of: :credential

    attribute :safe_metadata, :json, default: -> { {} }
    attribute :target_constraints, :json, default: -> { {} }
    attribute :allowed_surfaces, :json, default: -> { [] }
    attribute :allowed_tools, :json, default: -> { [] }

    encrypts :payload

    validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
    validates :description, length: { maximum: DESCRIPTION_MAX_LENGTH }, allow_nil: true
    validates :credential_type, presence: true, format: { with: TYPE_NAME_PATTERN }
    validates :scope_type, presence: true, inclusion: { in: ALLOWED_SCOPES }
    validates :payload, presence: true
    validate :scope_record_is_valid
    validate :safe_metadata_is_display_safe
    validate :target_constraints_are_valid
    validate :allowed_surface_names_are_valid
    validate :allowed_tool_names_are_valid
    validate :revoked_at_is_not_before_rotation

    scope :active, -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    before_validation :normalize_values
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "CredentialStore::Credential is revocation-only" }

    def revoked?
      revoked_at.present?
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def active?
      !revoked? && !expired?
    end

    def scope_policy
      CredentialScope::Base.for(scope_type)
    end

    def scope_record
      scope_policy.record_for(scope_id)
    end

    private

    def normalize_values
      self.name = name.to_s.strip.presence
      self.description = description.to_s.strip.presence if description
      self.credential_type = credential_type.to_s.strip.downcase.presence
      self.scope_type = scope_type.to_s.strip.downcase.presence
      self.safe_metadata = safe_metadata.presence || {}
      self.target_constraints = target_constraints.presence || {}
      self.allowed_surfaces = normalized_string_array(allowed_surfaces)
      self.allowed_tools = normalized_string_array(allowed_tools)
    end

    def normalized_string_array(value)
      Array(value).filter_map { |item| item.to_s.strip.presence }.uniq
    end

    def scope_record_is_valid
      return if scope_type.blank?

      scope_policy.validate!(self)
    rescue KeyError
      errors.add(:scope_type, "is not supported")
    end

    def safe_metadata_is_display_safe
      unless safe_metadata.is_a?(Hash)
        errors.add(:safe_metadata, "must be an object")
        return
      end

      validate_json_size(:safe_metadata, safe_metadata, SAFE_METADATA_MAX_BYTES)
      unknown_keys = safe_metadata.keys.map(&:to_s) - SAFE_METADATA_KEYS
      errors.add(:safe_metadata, "contains unsupported keys: #{unknown_keys.sort.join(', ')}") if unknown_keys.any?

      unsafe_key = safe_metadata.keys.map(&:to_s).find { |key| key.match?(SECRET_KEY_PATTERN) }
      errors.add(:safe_metadata, "must not include secret-bearing keys") if unsafe_key

      secret_like_value = safe_metadata.any? do |_key, value|
        value.is_a?(Hash) || value.is_a?(Array) || value.to_s.match?(SECRET_KEY_PATTERN)
      end
      errors.add(:safe_metadata, "must contain only safe display values") if secret_like_value
    end

    def target_constraints_are_valid
      unless target_constraints.is_a?(Hash)
        errors.add(:target_constraints, "must be an object")
        return
      end

      validate_json_size(:target_constraints, target_constraints, TARGET_CONSTRAINTS_MAX_BYTES)
      unknown_keys = target_constraints.keys.map(&:to_s) - TARGET_CONSTRAINT_KEYS
      errors.add(:target_constraints, "contains unsupported keys: #{unknown_keys.sort.join(', ')}") if unknown_keys.any?
      target_constraints.each do |key, value|
        errors.add(:target_constraints, "#{key} must be an array") unless value.is_a?(Array)
      end
    end

    def allowed_surface_names_are_valid
      validate_allowed_names(:allowed_surfaces, allowed_surfaces)
    end

    def allowed_tool_names_are_valid
      validate_allowed_names(:allowed_tools, allowed_tools)
    end

    def validate_allowed_names(attribute, values)
      unless values.is_a?(Array)
        errors.add(attribute, "must be an array")
        return
      end

      invalid = values.reject { |value| value.is_a?(String) && value.match?(ALLOWED_VALUE_PATTERN) }
      errors.add(attribute, "contain invalid names: #{invalid.join(', ')}") if invalid.any?
    end

    def validate_json_size(attribute, value, max_bytes)
      return if JSON.generate(value).bytesize <= max_bytes

      errors.add(attribute, "is too large")
    end

    def revoked_at_is_not_before_rotation
      return if revoked_at.blank? || last_rotated_at.blank?

      errors.add(:revoked_at, "cannot be before last_rotated_at") if revoked_at < last_rotated_at
    end
  end
end
