module Syrus
  class PluginRegistry
    EXTENSION_POINTS = %i[
      agent_provider
      mcp_tool_set
      input_source
      prompt_injector
      artifact_renderer
      test_result_parser
      coverage_analyzer
      preview_provider
    ].freeze

    @providers = Hash.new { |h, k| h[k] = [] }

    class << self
      def register(extension_point, provider)
        validate!(extension_point)
        @providers[extension_point.to_sym] << provider
      end

      def providers_for(extension_point)
        validate!(extension_point)
        @providers[extension_point.to_sym].dup
      end

      def reset!
        @providers = Hash.new { |h, k| h[k] = [] }
      end

      private

      def validate!(extension_point)
        return if EXTENSION_POINTS.include?(extension_point.to_sym)

        raise ArgumentError, "Unknown extension point: #{extension_point}. " \
          "Valid extension points: #{EXTENSION_POINTS.join(', ')}"
      end
    end
  end
end
