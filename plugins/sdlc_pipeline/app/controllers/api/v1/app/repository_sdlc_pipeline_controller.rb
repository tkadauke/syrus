module Api
  module V1
    module App
      class RepositorySdlcPipelineController < BaseController
        include RepositoryTabsSerialization

        def show
          repository = ::Repository.accessible_to(Current.user).find(params[:repository_id])
          projection = ::SdlcPipeline::Projection.new(
            repository: repository,
            user: Current.user,
            stage: params[:stage],
            page: params[:page] || 1,
            limit: params[:limit] || ::SdlcPipeline::Projection::PAGE_DEFAULT
          ).call

          render json: projection.merge(
            repository: { id: repository.id, slug: repository.slug },
            tabs: repository_tabs_json(repository)
          )
        end
      end
    end
  end
end
