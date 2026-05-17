module Filters
  module Chips
    # Boolean presence check: "has a PR" / "no PR". Models the legacy
    # `pr=has_pr/no_pr` dropdown semantics as a boolean chip rather
    # than an enum, since the value is the operator (is_true /
    # is_false) — no separate dropdown is needed.
    class PrPresent < Base
      filter_name "pr_present"
      label "PR"
      bucket :boolean
      operators :is_true, :is_false

      def apply
        case op
        when :is_true  then scope.with_pr
        when :is_false then scope.without_pr
        when :is
          value.to_s == "has" ? scope.with_pr : scope.without_pr
        else unsupported_op!
        end
      end
    end
  end
end
