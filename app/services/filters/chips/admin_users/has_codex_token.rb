module Filters
  module Chips
    module AdminUsers
      class HasCodexToken < TokenPresence
        filter_name "has_codex_token"
        label "Codex token"

        private

        def present_scope
          scope.where.not(codex_api_key: nil).or(scope.where.not(codex_auth_json: nil))
        end

        def missing_scope
          scope.where(codex_api_key: nil, codex_auth_json: nil)
        end
      end
    end
  end
end
