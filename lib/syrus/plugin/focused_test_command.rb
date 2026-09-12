module Syrus
  module Plugin
    # Interface for `:focused_test_command` extension points. Providers turn a
    # full grader command plus concrete failed test cases into a narrower
    # command that can be run at a base revision for base-revision retry (BRR).
    #
    # Implementations must define:
    #
    #   command_for(grader_name:, grader_command:, failed_cases:) -> String | nil
    #     Return a shell command that deterministically runs the failed cases,
    #     or nil to decline. `base_retry` is the parsed `.syrus.yml`
    #     configuration for the grader; providers should only synthesize a
    #     command for strategies they explicitly own. `failed_cases` are hashes
    #     with string keys: "suite_name", "name", "file_path", and "identity".
    module FocusedTestCommand
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def command_for(grader_name:, grader_command:, failed_cases:, base_retry:)
          raise NotImplementedError, "#{self}.command_for is required"
        end
      end

      def command_for(grader_name:, grader_command:, failed_cases:, base_retry:)
        raise NotImplementedError, "#{self.class}#command_for is required"
      end
    end
  end
end
