module Filters
  module Chips
    module Jobs
      # Tri-state column (true / false / nil "unknown"). Modeled as a
      # boolean chip with predicate operators rather than an enum
      # dropdown — the operator IS the value, so `is_true` / `is_false`
      # / `is_set` / `is_unset` cover all four states without an extra
      # value picker. `is_unset` matches "unknown" (NULL); `is_set`
      # matches the two known states.
      class PrMergeable < Base
        filter_name "pr_mergeable"
        label "PR mergeable"
        bucket :boolean
        operators :is_true, :is_false, :is_set, :is_unset

        def apply
          case op
          when :is_true  then scope.where(pr_mergeable: true)
          when :is_false then scope.where(pr_mergeable: false)
          when :is_set   then scope.where.not(pr_mergeable: nil)
          when :is_unset then scope.where(pr_mergeable: nil)
          else unsupported_op!
          end
        end
      end
    end
  end
end
