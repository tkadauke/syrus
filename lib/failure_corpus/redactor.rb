# frozen_string_literal: true

module FailureCorpus
  # Scrubs failure text before it leaves the production instance and lands in
  # a committed fixture.
  #
  # Plain Ruby on purpose: bin/export-failure-corpus streams this file into a
  # production `rails runner`, which runs whatever release is deployed there,
  # so it cannot lean on application classes that release may not have.
  #
  # Two jobs, in this order:
  #   1. secrets -- credentials embedded in URLs, provider and GitHub tokens,
  #      bearer headers, key=value assignments, private keys;
  #   2. anonymization -- internal hostnames, home directories, e-mail
  #      addresses and GitHub owner/repo names, which mean nothing outside the
  #      instance they came from.
  #
  # Neither pass may erase the words the failure classifier reads. A redacted
  # credential keeps its surrounding identifier (`x-access-token:`,
  # `token=`), so a pattern like "invalid token" or a logged authenticated
  # push URL still reads the same way after scrubbing.
  module Redactor
    REDACTED = "[REDACTED]"

    URL_CREDENTIAL = %r{\b([a-z][a-z0-9+.-]*://)([^:/@\s"'<>]+):([^@\s"'<>]+)@}i
    URL_TOKEN_USER = %r{\b(https?://)((?:gh[pousr]|github_pat)_[A-Za-z0-9_]+)@}i

    TOKEN_PATTERNS = [
      /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{10,}\b/,
      /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
      /\bsk-ant-[A-Za-z0-9_\-]{10,}/,
      /\b(?:sk|rk|pk)-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{20,}/,
      /\bxox[abposr]-[A-Za-z0-9\-]{10,}/,
      /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
      /\bAIza[0-9A-Za-z_\-]{30,}/,
      /\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/,
      /\bglpat-[A-Za-z0-9_\-]{16,}/,
      /\bnpm_[A-Za-z0-9]{30,}/
    ].freeze

    PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/m
    BEARER = /\b(Bearer|Basic|token)\s+([A-Za-z0-9_\-.=+\/]{12,})/
    AUTH_HEADER = /\b((?:Proxy-)?Authorization\s*:\s*)(?!Bearer\b|Basic\b|token\b)[^\s"',}]+/i

    SENSITIVE_KEY = /
      (?:password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|
         credential|auth[_-]?key|session[_-]?key|client[_-]?secret|lease[_-]?id|
         invocation[_-]?context|cookie)
    /ix
    ASSIGNMENT = /
      (?<key>\b[A-Za-z_][A-Za-z0-9_.\-]*)
      (?<sep>["']?\s*[:=]\s*)
      (?<value>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s"',;&}\]]+)
    /x

    INTERNAL_HOST = /\b(?:[a-z0-9-]+\.)+(?:green-acres\.estate|internal|local|lan|home\.arpa|cluster\.local)\b/i
    HOME_DIR = %r{(/(?:Users|home))/(?!user/)[A-Za-z0-9._-]+}
    EMAIL = /\b[A-Za-z0-9._%+-]+@(?!github\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
    GITHUB_REPO = %r{(github\.com[/:])(?!example/)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?(?=\.git\b|[/\s"'#?)\]]|\z)}i

    # Instance-specific names -- repository owners and names, user handles and
    # names -- that the generic patterns cannot know. The exporter loads them
    # from the instance it runs on; each is replaced wherever it appears as a
    # whole word.
    def self.identifiers=(names)
      words = Array(names).map(&:to_s).map(&:strip).reject { |name| name.length < 3 }.uniq
      @identifier_pattern = words.empty? ? nil : /(?<![A-Za-z0-9])(?:#{words.sort_by { |w| -w.length }.map { |w| Regexp.escape(w) }.join("|")})(?![A-Za-z0-9])/i
    end

    def self.identifier_pattern = @identifier_pattern

    module_function

    def call(value)
      case value
      when String then scrub(value)
      when Array then value.map { |item| call(item) }
      when Hash then value.to_h { |key, item| [ key, call(item) ] }
      else value
      end
    end

    def scrub(text)
      out = utf8(text)
      out = out.gsub(PRIVATE_KEY, "[REDACTED PRIVATE KEY]")
      out = out.gsub(URL_TOKEN_USER) { "#{Regexp.last_match(1)}#{REDACTED}@" }
      out = out.gsub(URL_CREDENTIAL) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}:#{REDACTED}@" }
      out = TOKEN_PATTERNS.reduce(out) { |current, pattern| current.gsub(pattern, REDACTED) }
      out = out.gsub(BEARER) { "#{Regexp.last_match(1)} #{REDACTED}" }
      out = out.gsub(AUTH_HEADER) { "#{Regexp.last_match(1)}#{REDACTED}" }
      out = redact_assignments(out)
      anonymize(out)
    end

    def redact_assignments(text)
      text.gsub(ASSIGNMENT) do |assignment|
        match = Regexp.last_match
        next assignment unless match[:key].match?(SENSITIVE_KEY)
        next assignment if match[:value].include?(REDACTED)
        # Prose such as "token: invalid" or "password: required" is evidence
        # the classifier reads, not a secret.
        next assignment if match[:value].match?(/\A["']?(?:invalid|expired|revoked|missing|required|null|nil|none|true|false|\[?filtered\]?)["']?\z/i)

        quote = %w[" '].include?(match[:value][0]) ? match[:value][0] : ""
        "#{match[:key]}#{match[:sep]}#{quote}#{REDACTED}#{quote}"
      end
    end

    def anonymize(text)
      text
        .gsub(INTERNAL_HOST, "host.example.test")
        .gsub(HOME_DIR) { "#{Regexp.last_match(1)}/user" }
        .gsub(EMAIL, "user@example.test")
        .gsub(GITHUB_REPO) { "#{Regexp.last_match(1)}example/repo" }
        .then { |out| Redactor.identifier_pattern ? out.gsub(Redactor.identifier_pattern, "example") : out }
    end

    # NUL bytes (`ls-files -z` output quoted in an error message) are dropped:
    # SQLite, which the replay runs on, cannot store them in a text column.
    def utf8(text)
      string = text.to_s
      string =
        if string.encoding == Encoding::ASCII_8BIT
          string.dup.force_encoding(Encoding::UTF_8).scrub("")
        else
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        end
      string.delete("\u0000")
    end

    # Keeps both ends of a long text. Failures put their cause at either end:
    # the command that ran at the top, the error at the bottom.
    def truncate(text, limit)
      string = text.to_s
      return string if string.length <= limit

      half = (limit - 40) / 2
      "#{string[0, half]}\n[... #{string.length - (half * 2)} chars elided ...]\n#{string[-half, half]}"
    end
  end
end
