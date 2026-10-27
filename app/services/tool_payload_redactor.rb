class ToolPayloadRedactor
  REDACTED = "[redacted]".freeze
  SENSITIVE_KEY = /(?:^|[_-])(?:access[_-]?token|api[_-]?key|apikey|authorization|auth[_-]?token|bearer|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)(?:[_-]|$)/i
  SAFE_METADATA_KEYS = %w[
    app_credential_inactive_reason credential_id credential_kind credential_mode
    credential_name credential_scope credential_scope_id credential_scope_type
    credential_status credential_type jwt_error_class jwt_error_message
  ].to_set.freeze

  def self.redact(value, parent_key = nil)
    case value
    when String
      CommandRedactor.redact(value).gsub(CommandRedactor::REDACTED, REDACTED)
    when Array
      value.map { |entry| redact(entry, parent_key) }
    when Hash
      value.each_with_object({}) do |(raw_key, entry), redacted|
        key = raw_key.to_s
        redacted[key] = sensitive_key?(key) && !SAFE_METADATA_KEYS.include?(normalize(key)) ? REDACTED : redact(entry, key)
      end
    else
      value
    end
  end

  def self.sensitive_key?(key)
    normalize(key).match?(SENSITIVE_KEY)
  end
  private_class_method :sensitive_key?

  def self.normalize(key)
    key.to_s.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
  end
  private_class_method :normalize
end
