module Api
  module V1
    module App
      class RepositoryPluginTabsController < BaseController
        def index
          repository = find_repository
          render json: Repositories::PluginRepoTabsPayload.new(repository: repository, user: Current.user).as_json
        end

        private

        def find_repository
          Repository.accessible_to(Current.user).find(params[:repository_id])
        end
      end
    end
  end
end
