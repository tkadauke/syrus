module OperatorBriefing
  module BlockPayloadNormalizers
    class Narrative < Base
      def normalize(payload)
        payload.slice("text", "dive_candidates").tap do |normalized|
          normalized["dive_candidates"] = normalize_dive_candidates(normalized["dive_candidates"])
        end.compact_blank
      end

      private

      def normalize_dive_candidates(candidates)
        Array(candidates).filter_map do |candidate|
          next unless candidate.is_a?(Hash)

          candidate = candidate.deep_stringify_keys
          text = candidate["text"].to_s.strip
          next if text.blank?

          candidate.slice("text", "prompt", "evidence", "topic_id").tap do |normalized|
            normalized["text"] = text.truncate(180)
            normalized["prompt"] = normalized["prompt"].to_s.strip.truncate(1_000) if normalized["prompt"].present?
            normalized["evidence"] = Array(normalized["evidence"]).first(10)
          end.compact_blank
        end.first(BriefingRevision::MAX_DIVE_CANDIDATES)
      end
    end
  end
end
