module CodeFacts
  class Complexity
    SUPPORTED_TYPES = %w[code test].freeze
    DECISION_PATTERN = /
      \b(if|elsif|else\s+if|unless|case|when|while|until|for|rescue|catch|switch)\b
      |(\&\&|\|\|)
      |\?
    /x.freeze
    DEFINITION_PATTERN = /\b(class|module|def|function|func|const|let|var)\b/.freeze
    DECISION_GREP_PATTERN = '(^|[^[:alnum:]_])(if|elsif|unless|case|when|while|until|for|rescue|catch|switch)([^[:alnum:]_]|$)|&&|\|\||\?'.freeze
    DEFINITION_GREP_PATTERN = "(^|[^[:alnum:]_])(class|module|def|function|func|const|let|var)([^[:alnum:]_]|$)".freeze

    def self.for(type:, decision_count:, definition_count:)
      return fallback unless SUPPORTED_TYPES.include?(type)

      score = decision_count.to_i + [ definition_count.to_i, 1 ].max
      { "score" => score, "source" => "heuristic" }
    end

    def self.fallback
      { "score" => nil, "source" => "unsupported" }
    end
  end
end
