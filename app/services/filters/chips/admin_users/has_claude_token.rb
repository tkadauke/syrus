module Filters
  module Chips
    module AdminUsers
      class HasClaudeToken < Base
        filter_name "has_claude_token"
        label "Claude token"
        bucket :enum
        operators :is
        values({ value: "true", label: "Set" }, { value: "false", label: "Missing" })

        def apply
          ActiveModel::Type::Boolean.new.cast(value) ? scope.where.not(claude_oauth_token: nil) : scope.where(claude_oauth_token: nil)
        end
      end
    end
  end
end
