module Filters
  module Chips
    module AdminUsers
      class HasMuseToken < TokenPresence
        filter_name "has_muse_token"
        label "Muse token"

        private

        def present_scope = scope.where.not(muse_api_key: nil)
        def missing_scope = scope.where(muse_api_key: nil)
      end
    end
  end
end
