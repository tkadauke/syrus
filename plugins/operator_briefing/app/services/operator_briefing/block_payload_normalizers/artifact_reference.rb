module OperatorBriefing
  module BlockPayloadNormalizers
    class ArtifactReference < Base
      def normalize(payload)
        payload.slice("workflow_id", "type", "title", "caption")
      end
    end
  end
end
