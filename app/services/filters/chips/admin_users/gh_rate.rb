module Filters
  module Chips
    module AdminUsers
      class GhRate < Base
        GH_RATE_LOW_THRESHOLD = 0.10

        filter_name "gh_rate"
        label "GH rate"
        bucket :enum
        operators :is
        values(
          { value: "low", label: "Low (<10%)" },
          { value: "exhausted", label: "Exhausted" }
        )

        def apply
          case value.to_s
          when "low"
            scope.where("gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0 AND gh_rate_limit_remaining < gh_rate_limit_limit * ?", GH_RATE_LOW_THRESHOLD)
          when "exhausted"
            scope.where(gh_rate_limit_remaining: 0)
          else
            scope
          end
        end
      end
    end
  end
end
