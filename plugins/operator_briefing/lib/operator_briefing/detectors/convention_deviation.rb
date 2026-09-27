module OperatorBriefing
  module Detectors
    class ConventionDeviation < Base
      PATTERNS = [
        /\ACLAUDE\.md\z/,
        /\AAGENTS\.md\z/,
        %r{\A\.claude/},
        %r{\Aconfig/syrus_docs/},
        %r{\Aapp/services/prompts/},
        %r{\Aapp/services/steps/},
        %r{\Alib/syrus/plugin_registry\.rb\z},
        %r{\Aplugins/[^/]+/docs/syrus_docs/},
        %r{\Aplugins/[^/]+/lib/}
      ].freeze

      def self.detector_key = "conventions"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        files = files_matching(changed_files, PATTERNS)
        return [] if files.empty?

        [ fact(
          key: "semantic_convention_review_required",
          severity: "attention_debt",
          summary: "Convention-sensitive files changed and need semantic review against repository guidance.",
          evidence: evidence_for(files)
        ) ]
      end
    end
  end
end
