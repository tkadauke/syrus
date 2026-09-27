module OperatorBriefing
  module BlockPayloadNormalizers
    class Base
      def self.for(kind)
        {
          "narrative" => Narrative,
          "chart" => Chart,
          "image" => ArtifactReference,
          "artifact" => ArtifactReference,
          "link_card" => LinkCard
        }.fetch(kind.to_s, self).new
      end

      def normalize(payload)
        payload
      end
    end
  end
end
