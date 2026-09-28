module CodeFacts
  class Complexity
    SUPPORTED_TYPES = %w[code test].freeze
    DECISION_PATTERN = /
      \b(if|elsif|else\s+if|unless|case|when|while|until|for|rescue|catch|switch)\b
      |(\&\&|\|\|)
      |\?
    /x.freeze
    DEFINITION_PATTERN = /\b(class|module|def|function|func|const|let|var)\b/.freeze

    def self.for(path:, type:, content:)
      return fallback unless SUPPORTED_TYPES.include?(type)
      return fallback if content.nil?

      text = content.to_s
      return fallback if text.include?("\x00")

      score = text.scan(DECISION_PATTERN).size + [ text.scan(DEFINITION_PATTERN).size, 1 ].max
      { "score" => score, "source" => "heuristic" }
    end

    def self.fallback
      { "score" => nil, "source" => "unsupported" }
    end
  end
end
