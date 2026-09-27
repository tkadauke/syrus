module OperatorBriefing
  module Detectors
    class SecuritySensitivePaths < Base
      PATTERNS = [
        %r{\Aapp/policies/},
        %r{\Aapp/services/.*/auth},
        %r{\Aapp/controllers/.*/sessions},
        %r{\Aconfig/credentials},
        %r{\Aconfig/master\.key\z},
        %r{\Aconfig/initializers/.*(auth|secret|permission|security)},
        %r{(^|/)(auth|authorization|permission|permissions|secret|secrets|credential|credentials)(/|_)}
      ].freeze

      def self.detector_key = "security_sensitive_paths"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        files = files_matching(changed_files, PATTERNS)
        return [] if files.empty?

        [ fact(
          key: "security_sensitive_paths_changed",
          severity: "decision_required",
          summary: "Security-sensitive paths changed.",
          evidence: evidence_for(files)
        ) ]
      end
    end
  end
end
