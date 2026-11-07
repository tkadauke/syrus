module Api
  module V1
    module Admin
      # Read-only build-cache bucket stats for external admin API clients.
      # Destructive clear actions require an operator confirmation step in
      # the SPA (Api::V1::App::Admin::BuildCacheController) and are not
      # exposed here.
      class BuildCacheController < BaseController
        def show
          include_stats = ActiveModel::Type::Boolean.new.cast(params.fetch(:include_stats, false))
          render json: ::BuildCache::Payload.new.show(include_stats: include_stats)
        end
      end
    end
  end
end
