class CommandRedactor
  REDACTED = "[REDACTED]".freeze

  AUTH_URL_PATTERNS = [
    %r{(https://x-access-token:)[^@\s]+(@)}i,
    %r{(https://[^:/@\s]+:)[^@\s]+(@github\.com\b)}i
  ].freeze
  GITHUB_TOKEN_PATTERN = /\b(?:ghp|github_pat|gho|ghu|ghs|ghr)_[A-Za-z0-9_]+\b/.freeze
  ASSIGNMENT_PATTERN = /(?<![A-Za-z0-9_-])(-{0,2})([A-Za-z_][A-Za-z0-9_-]*)=(["']?)([^&\s"']+)/.freeze
  SENSITIVE_ASSIGNMENT_SEGMENTS = %w[authorization password passwd secret token key apikey].freeze
  SECRET_ASSIGNMENT_PATTERNS = [
    /((?:access|refresh|id)_token["']?\s*[:=]\s*["']?)[^"',\s}]+/i,
    /((?:SYRUS_(?:CLI|MCP_PROXY)_INVOCATION_CONTEXT|invocation_context)["']?\s*[:=]\s*["']?)[^"',\s}]+/i,
    /((?:credential_)?lease_id["']?\s*[:=]\s*["']?)[^"',\s}]+/i
  ].freeze

  def self.redact(text)
    redacted = AUTH_URL_PATTERNS
      .reduce(utf8(text)) { |redacted, pattern| redacted.gsub(pattern, "\\1#{REDACTED}\\2") }
      .gsub(GITHUB_TOKEN_PATTERN, REDACTED)
    redacted = redact_assignments(redacted)
    SECRET_ASSIGNMENT_PATTERNS.reduce(redacted) { |current, pattern| current.gsub(pattern, "\\1#{REDACTED}") }
  end

  def self.redact_assignments(text)
    utf8(text).gsub(ASSIGNMENT_PATTERN) do |assignment|
      prefix = Regexp.last_match(1)
      key = Regexp.last_match(2)
      quote = Regexp.last_match(3)
      sensitive_assignment_key?(key) ? "#{prefix}#{key}=#{quote}#{REDACTED}" : assignment
    end
  end

  def self.sensitive_assignment_key?(key)
    (key.downcase.split(/[_-]+/) & SENSITIVE_ASSIGNMENT_SEGMENTS).any?
  end

  def self.redact_value(value)
    case value
    when String
      redact(value)
    when Array
      value.map { |item| redact_value(item) }
    when Hash
      value.transform_values { |item| redact_value(item) }
    else
      value
    end
  end

  def self.utf8(text)
    string = text.to_s
    if string.encoding == Encoding::ASCII_8BIT
      string.dup.force_encoding(Encoding::UTF_8).scrub("")
    else
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end
  end
end
