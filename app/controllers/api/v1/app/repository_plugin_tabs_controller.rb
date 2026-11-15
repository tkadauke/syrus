module Api
  module V1
    module App
      class RepositoryPluginTabsController < BaseController
        def index
          repository = find_repository
          payload = ::Repositories::PluginRepoTabsPayload.new(repository: repository, user: Current.user).as_json
          response.headers["Cache-Control"] = "private, max-age=60"
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end

        private

        def find_repository
          Repository.accessible_to(Current.user).find(params[:repository_id])
        end
      end
    end
  end
end
