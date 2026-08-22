module Api
  module V1
    module Admin
      # Read-only build-cache bucket stats for external admin API clients.
      # Destructive clear actions require an operator confirmation step in
      # the SPA (Api::V1::App::Admin::BuildCacheController) and are not
      # exposed here.
      class BuildCacheController < BaseController
        def show
          render json: ::Admin::BuildCache::Payload.new.show
        end
      end
    end
  end
end
