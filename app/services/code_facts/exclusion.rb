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

    def initialize(config:)
      @config = config
    end

    def reasons_for(path)
      reasons = []
      reasons << "vendor" if RepositoryContent::Glob.match?(VENDOR_PATTERNS, path)
      reasons << "generated" if generated?(path)
      reasons
    end

    private

    attr_reader :config

    def generated?(path)
      RepositoryContent::Glob.match?(GENERATED_PATTERNS, path) ||
        RepositoryContent::Glob.match?(configured_generated_patterns, path)
    end

    def configured_generated_patterns
      return [] unless config&.generated.is_a?(Array)

      config.generated.flat_map(&:generates)
    end
  end
end
