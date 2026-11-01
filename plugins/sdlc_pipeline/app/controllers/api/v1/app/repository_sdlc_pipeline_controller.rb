module Api
  module V1
    module App
      class RepositorySdlcPipelineController < BaseController
        include RepositoryTabsSerialization

        def show
          repository = ::Repository.accessible_to(Current.user).find(params[:repository_id])
          ::SmartFolder.ensure_builtins_for_subject!(::SdlcPipeline::SmartFolders::SUBJECT)
          active_folder = ::Admin::SmartFolderNavigation.active_folder(
            subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Current.user, params: params
          )
          resolution = ::Filters::SmartFolderResolution.call(
            filter_class: ::SdlcPipeline::Filter, subject: ::SdlcPipeline::SmartFolders::SUBJECT,
            params: params, active_smart_folder: active_folder, user: Current.user
          )
          projection = ::SdlcPipeline::Projection.new(
            repository: repository,
            user: Current.user,
            filter: resolution.filter,
            stage: params[:stage],
            page: params[:page] || 1,
            limit: params[:limit] || ::SdlcPipeline::Projection::PAGE_DEFAULT
          ).call
          history = ::SdlcPipeline::History.new(
            repository: repository, user: Current.user, filter: resolution.filter,
            from: params[:range_start], to: params[:range_end]
          ).call

          render json: projection.merge(
            history: history,
            repository: { id: repository.id, slug: repository.slug },
            tabs: repository_tabs_json(repository),
            active_smart_folder_id: active_folder&.id,
            filter_schema: ::Filters::Schema.for(subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Current.user),
            smart_folders: ::Admin::SmartFolderNavigation.new(
              subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Current.user, active_folder: active_folder,
              base_scope: ::Job.visible_to(Current.user).where(repository_id: repository.id),
              filter_class: ::SdlcPipeline::Filter, path_context: { repository_id: repository.id }
            ).folders
          )
        end
      end
    end
  end
end
