module Syrus
  module Plugin
    # Interface for `:notable_change_detector` extension points. Providers run
    # against one Workflow diff and return structured facts for operator
    # briefing and other "what changed here?" surfaces.
    #
    # Implementations must define:
    #
    #   detector_key -> String
    #     Stable key used for idempotency and filtering.
    #
    #   detect(workflow:, diff:, changed_files:, name_status:, workspace_path:) -> Array<Hash>
    #     Returns facts shaped like:
    #       { key:, severity:, summary:, evidence: [{ file:, line: }] }
    module NotableChangeDetector
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def detector_key
          raise NotImplementedError, "#{self}.detector_key is required"
        end

        def detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
          raise NotImplementedError, "#{self}.detect is required"
        end
      end

      def detector_key
        raise NotImplementedError, "#{self.class}#detector_key is required"
      end

      def detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        raise NotImplementedError, "#{self.class}#detect is required"
      end
    end
  end
end
