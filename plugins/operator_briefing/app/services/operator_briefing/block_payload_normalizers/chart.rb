module OperatorBriefing
  module BlockPayloadNormalizers
    class Chart < Base
      def normalize(payload)
        payload.slice("chart_type", "title", "data").tap do |normalized|
          normalized["chart_type"] = normalized["chart_type"].to_s if BriefingRevision::CHART_TYPES.include?(normalized["chart_type"].to_s)
          normalized["data"] = [] unless normalized["data"].is_a?(Array)
        end
      end
    end
  end
end
