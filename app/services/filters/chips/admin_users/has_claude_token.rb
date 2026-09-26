module Filters
  module Chips
    module AdminUsers
      class HasClaudeToken < TokenPresence
        filter_name "has_claude_token"
        label "Claude token"

        private

        def present_scope = scope.where.not(claude_oauth_token: nil)
        def missing_scope = scope.where(claude_oauth_token: nil)
      end
    end
  end
end
