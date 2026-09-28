module CodeFacts
  class Exclusion
    VENDOR_PATTERNS = [
      ".bundle/**",
      "node_modules/**",
      "vendor/**"
    ].freeze

    GENERATED_PATTERNS = [
      "**/*.generated.*",
      "**/__generated__/**",
      "__generated__/**",
      "db/schema.rb"
    ].freeze

    def initialize(generated_patterns:)
      @generated_patterns = generated_patterns
    end

    def reasons_for(path)
      reasons = []
      reasons << "vendor" if RepositoryContent::Glob.match?(VENDOR_PATTERNS, path)
      reasons << "generated" if generated?(path)
      reasons
    end

    private

    attr_reader :generated_patterns

    def generated?(path)
      RepositoryContent::Glob.match?(GENERATED_PATTERNS, path) ||
        RepositoryContent::Glob.match?(generated_patterns, path)
    end
  end
end
