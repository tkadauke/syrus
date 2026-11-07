module Api
  module V1
    module App
      class RepositoryPluginTabsController < BaseController
        def index
          repository = find_repository
          payload = ::Repositories::PluginRepoTabsPayload.new(repository: repository, user: Current.user).as_json
          expires_in 30.seconds, public: false
          render json: payload if stale?(etag: payload, public: false)
        end

        private

        def find_repository
          Repository.accessible_to(Current.user).find(params[:repository_id])
        end
      end
    end
  end
end
