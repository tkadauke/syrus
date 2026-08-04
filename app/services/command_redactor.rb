class CommandRedactor
  REDACTED = "[REDACTED]".freeze

  AUTH_URL_PATTERN = %r{(https://x-access-token:)[^@\s]+(@)}.freeze
  GITHUB_TOKEN_PATTERN = /\b(?:ghp|github_pat|gho|ghu|ghs|ghr)_[A-Za-z0-9_]+\b/.freeze

  def self.redact(text)
    utf8(text)
      .gsub(AUTH_URL_PATTERN, "\\1#{REDACTED}\\2")
      .gsub(GITHUB_TOKEN_PATTERN, REDACTED)
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
