module OperatorBriefing
  module BlockPayloadNormalizers
    class LinkCard < Base
      def normalize(payload)
        payload.slice("entity_type", "entity_id", "title", "path", "description").tap do |normalized|
          normalized["path"] = normalize_path(normalized["path"]) if normalized.key?("path")
        end
      end

      private

      def normalize_path(path)
        return path if path.nil?

        path.to_s.sub(%r{\A(/design_docs/)DOC-(\d+)(?=\z|[/?#])}i, '\1\2')
      end
    end
  end
end
