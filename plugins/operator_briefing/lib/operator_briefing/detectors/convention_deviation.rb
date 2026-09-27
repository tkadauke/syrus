module OperatorBriefing
  module Detectors
    class ConventionDeviation < Base
      def self.detector_key = "conventions"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        []
      end
    end
  end
end
