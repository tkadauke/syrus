module OperatorBriefing
  module Detectors
    class TestCoverageChanges < Base
      TEST_PATTERNS = [
        %r{\Aspec/},
        %r{\Atest/},
        %r{(^|/)__tests__/},
        /(_spec|\.test)\.(rb|js|jsx|ts|tsx)\z/
      ].freeze

      def self.detector_key = "test_coverage"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        removed_tests = files_matching(deleted_files(name_status), TEST_PATTERNS)
        weakened_lines = diff.to_s.lines.select do |line|
          line.start_with?("-") && !line.start_with?("---") && line.match?(/\b(skip|pending|xit|xdescribe|allow\(.*\)\.to receive|without tests)\b/i)
        end
        return [] if removed_tests.empty? && weakened_lines.empty?

        evidence = evidence_for(removed_tests)
        evidence << { "diff" => weakened_lines.first(5).map(&:strip) } if weakened_lines.any?
        [ fact(
          key: "tests_removed_or_weakened",
          severity: "attention_debt",
          summary: "Test coverage may have been deleted or weakened.",
          evidence: evidence
        ) ]
      end
    end
  end
end
