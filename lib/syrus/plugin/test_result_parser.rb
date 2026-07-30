module Syrus
  module Plugin
    # Interface for custom test result parsers registered with
    # PluginRegistry under :test_result_parser.
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
    #   Syrus::PluginRegistry.register(:test_result_parser, MyParser.new)
    module TestResultParser
      def can_parse?(output_path:, format_hint: nil)
        raise NotImplementedError, "#{self.class}#can_parse? is not implemented"
      end

      def call(output_path:, format_hint: nil)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end
    end
  end
end
