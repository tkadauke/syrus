module Filters
  module Chips
    module SpawnedProcesses
      class Stale < Base
        filter_name "stale"
        label "Stale"
        bucket :enum
        operators :is
        values({ value: "true", label: "Stale - no output for 5+ min" })

        def apply
          case op
          when :is
            value.to_s == "true" ? scope.stale : scope.none
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
