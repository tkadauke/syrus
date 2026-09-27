module OperatorBriefing
  module BlockPayloadNormalizers
    class LinkCard < Base
      def normalize(payload)
        payload.slice("entity_type", "entity_id", "title", "path", "description")
      end
    end
  end
end
