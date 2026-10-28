class ToolPayloadRedactor
  REDACTED = "[redacted]".freeze
  SENSITIVE_KEY = /(?:^|[_-])(?:access[_-]?token|api[_-]?key|apikey|authorization|auth[_-]?token|bearer|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)(?:[_-]|$)/i
  INLINE_SECRET_ASSIGNMENT_KEY = /[A-Za-z0-9_-]*(?:access[_-]?token|api[_-]?key|apikey|auth[_-]?token|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)[A-Za-z0-9_-]*/i
  SAFE_METADATA_KEYS = %w[
    app_credential_inactive_reason credential_id credential_kind credential_mode
    credential_name credential_scope credential_scope_id credential_scope_type
    credential_status credential_type jwt_error_class jwt_error_message
  ].to_set.freeze
  IDENTIFIER_VALUE_KEY = /(?:^|_)(?:key_names?|resource_names?|name)$/i
  SECRET_RESOURCE_METADATA_KEY = /\A(?:name|namespace|type|key_count|key_names|immutable|owner_references|created_at)\z/i
  CREDENTIAL_METADATA_KEY = /\A(?:credential_id|credential_name|credential_type)\z/i
  DESIGN_TOKEN_CONTAINER_KEY = /\A(?:tokens|light|dark)\z/i

  def self.redact(value, parent_key = nil)
    case value
    when String
      redact_text(value, redact_bare_secret_identifier: !identifier_value_key?(parent_key))
    when Array
      value.map { |entry| redact(entry, parent_key) }
    when Hash
      value.each_with_object({}) do |(raw_key, entry), redacted|
        key = raw_key.to_s
        redacted[key] = redact_entry(key, entry)
      end
    else
      value
    end
  end

  def self.redact_text(text, redact_bare_secret_identifier: true)
    redacted = CommandRedactor.utf8(text)
      .gsub(/-----BEGIN (?:[^-\r\n]+ )?PRIVATE KEY-----.*?-----END (?:[^-\r\n]+ )?PRIVATE KEY-----/mi, REDACTED)
      .gsub(%r{(\b[a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s/@]+(@)}i, "\\1#{REDACTED}\\2")
      .gsub(/(\s-u\s+[^\s:]+:)([^\s]+)/, "\\1#{REDACTED}")
      .gsub(/\b(Bearer\s+)[A-Za-z0-9._~+\/=\-]{12,}/i, "\\1#{REDACTED}")
      .gsub(/(["'])(accessToken|access[_-]?token|apiKey|api[_-]?key|apikey|clientSecret|client[_-]?secret|credential|idToken|id[_-]?token|password|refreshToken|refresh[_-]?token|secret|sessionToken|session[_-]?token)\1(\s*:\s*)(["'])[^"']{6,}\4/i, "\\1\\2\\1\\3\\4#{REDACTED}\\4")

    redacted = redact_inline_assignments(redacted)
      .gsub(/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/, REDACTED)
      .gsub(/\bsk-[A-Za-z0-9_-]{20,}\b/, REDACTED)
    return redacted unless redact_bare_secret_identifier

    redacted.gsub(/\b[A-Za-z0-9._-]*(?:credential|password|secret|token)[A-Za-z0-9._-]{6,}\b(?!\s*[:=])/i, REDACTED)
  end

  def self.redact_entry(key, value)
    return redact(value, key) if normalize(key).match?(DESIGN_TOKEN_CONTAINER_KEY)
    return redact(value, key) unless sensitive_key?(key) && !safe_metadata_key?(key)
    return value unless value.is_a?(String) || value.is_a?(Array) || value.is_a?(Hash)
    return redact_credential_metadata(value) if credential_metadata_object?(key, value)
    return redact_secret_resource_metadata(value) if secret_resource_metadata_object?(key, value)

    REDACTED
  end
  private_class_method :redact_entry

  def self.redact_inline_assignments(text)
    text.gsub(/(?<![A-Za-z])(#{INLINE_SECRET_ASSIGNMENT_KEY})(\s*[:=]\s*)("(?:\\.|[^"\\\n\r])*"|'(?:\\.|[^'\\\n\r])*'|[^\s,;}]+)/) do
      key = Regexp.last_match(1)
      separator = Regexp.last_match(2)
      value = Regexp.last_match(3)
      quote = value.start_with?('"', "'") ? value[0] : ""
      "#{key}#{separator}#{quote}#{REDACTED}#{quote}"
    end
  end
  private_class_method :redact_inline_assignments

  def self.redact_credential_metadata(value)
    value.each_with_object({}) do |(raw_key, entry), redacted|
      key = raw_key.to_s
      redacted[key] = normalize(key).match?(CREDENTIAL_METADATA_KEY) ? redact(entry, key) : REDACTED
    end
  end
  private_class_method :redact_credential_metadata

  def self.redact_secret_resource_metadata(value)
    value.each_with_object({}) do |(raw_key, entry), redacted|
      key = raw_key.to_s
      redacted[key] = normalize(key).match?(SECRET_RESOURCE_METADATA_KEY) ? redact(entry, key) : REDACTED
    end
  end
  private_class_method :redact_secret_resource_metadata

  def self.credential_metadata_object?(key, value)
    value.is_a?(Hash) && normalize(key).match?(/(?:^|_)credential$/)
  end
  private_class_method :credential_metadata_object?

  def self.secret_resource_metadata_object?(key, value)
    value.is_a?(Hash) && normalize(key) == "secret"
  end
  private_class_method :secret_resource_metadata_object?

  def self.sensitive_key?(key)
    normalize(key).match?(SENSITIVE_KEY)
  end
  private_class_method :sensitive_key?

  def self.safe_metadata_key?(key)
    SAFE_METADATA_KEYS.include?(normalize(key))
  end
  private_class_method :safe_metadata_key?

  def self.identifier_value_key?(key)
    normalize(key).match?(IDENTIFIER_VALUE_KEY)
  end
  private_class_method :identifier_value_key?

  def self.normalize(key)
    key.to_s.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
  end
  private_class_method :normalize
end
