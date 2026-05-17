module Filters
  module Chips
    module Jobs
      # Boolean presence check: "has a PR" / "no PR". Models the legacy
      # `pr=has_pr/no_pr` dropdown semantics as a boolean chip rather
      # than an enum, since the value is the operator (is_true /
      # is_false) — no separate dropdown is needed.
      class PrPresent < BooleanColumn
        filter_name "pr_present"
        label "PR"
        operators :is, :is_true, :is_false
        true_scope :with_pr
        false_scope :without_pr

        def apply
          return super unless op == :is

          case value.to_s
          when "has", "has_pr", "true" then scope.with_pr
          when "none", "no", "no_pr", "false" then scope.without_pr
          else unsupported_op!
          end
        end
      end
    end
  end
end
