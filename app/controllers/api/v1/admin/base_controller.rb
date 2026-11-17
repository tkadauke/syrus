module Api
  module V1
    module Admin
      # Shared base for /api/v1/admin/* — admin-token gated,
      # JSON-only, errors via render_error.
      class BaseController < Api::BaseController
        before_action :require_admin_api

        private

        def truthy?(value)
          %w[true 1 yes].include?(value.to_s.downcase)
        end
      end
    end
  end
end
