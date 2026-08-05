class CommandRedactor
  REDACTED = "[REDACTED]".freeze

  AUTH_URL_PATTERNS = [
    %r{(https://x-access-token:)[^@\s]+(@)}i,
    %r{(https://[^:/@\s]+:)[^@\s]+(@github\.com\b)}i
  ].freeze
  GITHUB_TOKEN_PATTERN = /\b(?:ghp|github_pat|gho|ghu|ghs|ghr)_[A-Za-z0-9_]+\b/.freeze

  def self.redact(text)
    AUTH_URL_PATTERNS
      .reduce(utf8(text)) { |redacted, pattern| redacted.gsub(pattern, "\\1#{REDACTED}\\2") }
      .gsub(GITHUB_TOKEN_PATTERN, REDACTED)
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
