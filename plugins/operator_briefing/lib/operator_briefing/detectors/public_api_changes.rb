module OperatorBriefing
  module Detectors
    class PublicApiChanges < Base
      PATTERNS = [
        %r{\Aconfig/routes\.rb\z},
        %r{\Aapp/controllers/api/},
        %r{\Aapp/serializers/},
        %r{\Aapp/services/mcp/tools/},
        %r{\Acli/},
        %r{\Aopenapi/},
        %r{\Aapi/}
      ].freeze

      def self.detector_key = "public_api"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        files = files_matching(changed_files, PATTERNS)
        return [] if files.empty?

        [ fact(
          key: "public_interface_changed",
          severity: "fyi",
          summary: "Public API or interface files changed.",
          evidence: evidence_for(files)
        ) ]
      end
    end
  end
end
