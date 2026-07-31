module SyrusMcp
  class EvidenceRedactor
    REDACTED = "[redacted]".freeze
    SECRET_PATTERNS = [
      %r{(https://x-access-token:)[^@\s]+(@)}i,
      /\bghp_[A-Za-z0-9_]{20,}\b/,
      /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
      /\b(?:sk|rk|sess|oat)-[A-Za-z0-9_\-]{16,}\b/,
      /
        \b[A-Za-z0-9_\-]*
        (?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)
        [A-Za-z0-9_\-]*\s*[:=]\s*["']?[^"'\s]+
      /ix
    ].freeze

    def self.call(value)
      return if value.nil?

      text = GitRunner.redact(SyrusMcp.utf8(value))
      SECRET_PATTERNS.each do |pattern|
        text = text.gsub(pattern) do |match|
          if match.include?("x-access-token:")
            match.gsub(%r{(https://x-access-token:)[^@\s]+(@)}i, "\\1#{REDACTED}\\2")
          elsif match.match?(/\A[A-Za-z0-9_\-]+\s*[:=]/)
            match.sub(/[:=]\s*["']?.+\z/, ": #{REDACTED}")
          else
            REDACTED
          end
        end
      end
      text
    end
  end
end
