module TestInsights
  # The contract for a test-result parser contributed through this plugin's
  # "test_insights:parser" point.
  #
  # Contributors are **not** expected to `include` this module. Doing so would
  # make them load a TestInsights constant, turning an optional hook into a
  # hard load-time dependency on this plugin -- language plugins contribute a
  # parser but must work perfectly well without test_insights installed. The
  # module documents the contract; contributors duck-type it.
  #
  # Interface for custom test result parsers registered with
  # PluginRegistry under "test_insights:parser".
  #
  # Implementations must define:
  #
  #   can_parse?(output_path:, format_hint: nil) -> Boolean
  #     Return true if this parser can handle the file at output_path.
  #     Called before JUnit XML fallback; returning false passes control
  #     to the next registered parser.
  #
  #   call(output_path:, format_hint: nil) -> parsed_run
  #     Parse the file and return an object duck-typed to
  #     JunitXmlParser::ParsedRun — i.e. it responds to:
  #       total_count, passed_count, failed_count, skipped_count,
  #       error_count, duration_ms, cases
  #     where each element of cases responds to:
  #       name, suite_name, file_path, status, duration_ms,
  #       output, failure_message, failure_backtrace
  #
  # Register an implementation at boot time:
  #   Syrus::PluginRegistry.register(
  #     name: "my-plugin",
  #     version: "1.0.0",
  #     provides: { "test_insights:parser" => MyParser }
  #   )
  # Interface for a test-result parser contributed through this plugin's
  # "test_insights:parser" extension point.
  module Parser
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def can_parse?(output_path:, format_hint: nil)
        raise NotImplementedError, "#{self.class}#can_parse? is not implemented"
      end

      def call(output_path:, format_hint: nil)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end
    end

    def can_parse?(output_path:, format_hint: nil)
      raise NotImplementedError, "#{self.class}#can_parse? is not implemented"
    end

    def call(output_path:, format_hint: nil)
      raise NotImplementedError, "#{self.class}#call is not implemented"
    end
  end
end
