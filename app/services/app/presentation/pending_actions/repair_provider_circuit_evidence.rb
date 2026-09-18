module App
  module Presentation
    module PendingActions
      class RepairProviderCircuitEvidence < Base
        action_key "repair_provider_circuit_evidence"

        def label
          "Repair #{payload['evidence_type']} evidence ##{payload['evidence_id']}"
        end

        def detail
          "Repair status: #{payload['repair_status']}"
        end
      end
    end
  end
end
