module OperatorBriefing
  module Detectors
    class DependencyChanges < Base
      LOCKFILE_PATTERNS = [
        /(^|\/)Gemfile\.lock\z/,
        /(^|\/)package-lock\.json\z/,
        /(^|\/)yarn\.lock\z/,
        /(^|\/)pnpm-lock\.yaml\z/,
        /(^|\/)poetry\.lock\z/,
        /(^|\/)uv\.lock\z/,
        /(^|\/)requirements.*\.txt\z/,
        /(^|\/)go\.sum\z/,
        /(^|\/)Cargo\.lock\z/
      ].freeze

      def self.detector_key = "dependencies"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        files = files_matching(changed_files, LOCKFILE_PATTERNS)
        return [] if files.empty?

        [ fact(
          key: "lockfiles_changed",
          severity: "fyi",
          summary: "Dependency lockfiles changed.",
          evidence: evidence_for(files)
        ) ]
      end
    end
  end
end
