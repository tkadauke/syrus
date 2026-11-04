module Coworkers
  class PushFailure
    TRANSIENT_PATTERNS = [
      /internal server error/i,
      /commit_refs/i,
      /\b(?:HTTP(?:\/\d(?:\.\d)?)?\s*|status(?: code)?\s*[=:]?\s*|returned error:\s*)5\d\d\b/i,
      /timed? out|timeout/i,
      /connection (?:reset|closed|refused)|could not resolve host|network (?:is )?unavailable|network is unreachable|empty reply from server/i
    ].freeze
    PERMANENT_PATTERNS = [
      /authentication failed|could not read username|permission denied|repository not found/i,
      /non-fast-forward|fetch first|failed to push some refs|protected branch|protected ref|denied to .*push/i
    ].freeze

    attr_reader :error

    def self.for(error)
      text = [ error.message, error.respond_to?(:output) ? error.output : nil ].compact.join("\n")
      return Transient.new(error) if TRANSIENT_PATTERNS.any? { |pattern| text.match?(pattern) }
      return Permanent.new(error) if PERMANENT_PATTERNS.any? { |pattern| text.match?(pattern) }

      Permanent.new(error)
    end

    def initialize(error) = @error = error
    def transient? = false
    def kind = "permanent"

    class Transient < PushFailure
      def transient? = true
      def kind = "transient"
    end

    class Permanent < PushFailure
    end
  end
end
