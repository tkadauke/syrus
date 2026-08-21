module Syrus
  module Plugin
    # Interface for CI log parser plugins registered with PluginRegistry
    # under :ci_log_parser. Providers are tried in registration order before
    # CiLogParser falls back to its own language-agnostic generic/fallback
    # parsers — mirrors the "plugin tries first, core generic parser is the
    # fallback" pattern used by :test_result_parser and :coverage_analyzer.
    #
    #   class MyCiLogParser
    #     include Syrus::Plugin::CiLogParser
    #
    #     def self.call(text:, step_name: nil)
    #       # Return a result Hash (see below) or nil if this parser doesn't
    #       # recognize the log.
    #     end
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my_ci_log_plugin", version: "1.0.0",
    #     provides: { ci_log_parser: MyCiLogParser }
    #   )
    module CiLogParser
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Attempts to parse the (already step-scoped) CI log text.
        #
        # @param text [String] the CI log, already scoped to the failing step
        # @param step_name [String, nil] the failing step's name, for context
        # @return [Hash, nil] a result Hash with the same shape CiLogParser's
        #   own parsers produce — +:parser+, +:error_summary+, +:error_block+,
        #   and optionally +:failing_tests+ / +:offenses+ — or nil if this
        #   parser doesn't recognize the log, passing control to the next
        #   registered parser (and eventually to the core fallback).
        def call(text:, step_name: nil)
          raise NotImplementedError, "#{self.class.name} must implement .call(text:, step_name:)"
        end
      end

      def call(text:, step_name: nil)
        raise NotImplementedError, "#{self.class.name} must implement #call(text:, step_name:)"
      end
    end
  end
end
