module OperatorBriefing
  module Detectors
    class SchemaChanges < Base
      PATTERNS = [
        %r{\Adb/migrate/},
        %r{\Adb/schema\.rb\z},
        %r{\Adb/structure\.sql\z}
      ].freeze

      def self.detector_key = "schema"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        files = files_matching(changed_files, PATTERNS)
        return [] if files.empty?

        [ fact(
          key: "schema_or_migration_changed",
          severity: "decision_required",
          summary: "Schema or migration files changed.",
          evidence: evidence_for(files)
        ) ]
      end
    end
  end
end
