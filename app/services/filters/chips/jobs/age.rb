module Filters
  module Chips
    module Jobs
      # Faithful port of the existing `age` dropdown — enum values
      # 1d/7d/30d filter to `created_at >= N.days.ago`. A richer date
      # chip with operators `before`/`after`/`within_last` etc. will
      # supersede this in a later commit; the named-enum stays for
      # back-compat with the current filter bar.
      class Age < Base
        filter_name "age"
        label "Age"
        bucket :enum
        operators :is

        CUTOFFS = {
          "1d"  => 1.day,
          "7d"  => 7.days,
          "30d" => 30.days
        }.freeze

        values(*CUTOFFS.keys)

        def apply
          case op
          when :is
            duration = CUTOFFS[value.to_s]
            duration ? scope.where(created_at: duration.ago..) : scope
          else unsupported_op!
          end
        end
      end
    end
  end
end
