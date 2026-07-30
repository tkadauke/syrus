module Syrus
  module Plugin
    # Interface for coverage analyzer plugins. Include this module in a class and
    # implement #call to register a custom coverage parser.
    #
    #   class MyCoverageAnalyzer
    #     include Syrus::Plugin::CoverageAnalyzer
    #
    #     def call(artifact_path:, format_hint: nil)
    #       # Return a CoverageAnalysis::Parsers::Base::ParseResult or nil
    #     end
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my_coverage_plugin", version: "1.0.0",
    #     provides: { coverage_analyzer: MyCoverageAnalyzer }
    #   )
    module CoverageAnalyzer
      # Analyzes a coverage artifact file and returns parsed coverage data.
      #
      # @param artifact_path [Pathname] path to the coverage artifact file
      # @param format_hint [String, nil] format declared in .syrus.yml (e.g. "lcov", "cobertura")
      # @return [CoverageAnalysis::Parsers::Base::ParseResult, nil] parsed result with #raw and
      #   #lines_pct, or nil if this analyzer cannot handle the given artifact
      def call(artifact_path:, format_hint: nil)
        raise NotImplementedError, "#{self.class.name} must implement #call(artifact_path:, format_hint:)"
      end
    end
  end
end
