module Syrus
  # Central registry for plugin extension points. Plugin gems call
  # PluginRegistry.register(:test_result_parser, MyParser.new) at boot
  # time to contribute implementations. Consumer code calls providers_for
  # to retrieve the registered providers for a given point.
  class PluginRegistry
    EXTENSION_POINTS = %i[
      test_result_parser
    ].freeze

    class << self
      def register(extension_point, provider)
        point = extension_point.to_sym
        raise ArgumentError, "Unknown extension point #{point.inspect}. Valid: #{EXTENSION_POINTS.inspect}" unless EXTENSION_POINTS.include?(point)
        providers[point] << provider
      end

      def providers_for(extension_point)
        point = extension_point.to_sym
        raise ArgumentError, "Unknown extension point #{point.inspect}. Valid: #{EXTENSION_POINTS.inspect}" unless EXTENSION_POINTS.include?(point)
        providers[point].dup
      end

      # Reset all registrations — for test isolation only.
      def reset!
        @providers = nil
      end

      private

      def providers
        @providers ||= Hash.new { |h, k| h[k] = [] }
      end
    end
  end
end
