module Filters
  module Chips
    module AdminUsers
      class HasApiToken < TokenPresence
        filter_name "has_api_token"
        label "API token"

        private

        def present_scope = scope.where.not(api_token: nil)
        def missing_scope = scope.where(api_token: nil)
      end
    end
  end
end
