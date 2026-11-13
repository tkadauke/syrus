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
          history_only = params[:history] == "only" || params[:section] == "history-only"
          projection = !history_only && ::SdlcPipeline::Projection.new(
            repository: repository,
            user: Current.user,
            filter: resolution.filter,
            stage: params[:stage],
            page: params[:page] || 1,
            limit: params[:limit] || ::SdlcPipeline::Projection::PAGE_DEFAULT
          ).call
          history = if history_only || params[:history] == "1"
            ::SdlcPipeline::History.new(
              repository: repository, user: Current.user, filter: resolution.filter,
              from: params[:range_start], to: params[:range_end]
            ).call.tap { |payload| payload.delete(:ticks) }
          end

          if history_only
            fresh_when(etag: [ repository.cache_key_with_version, resolution.filter.to_h, params[:range_start], params[:range_end] ])
            return if request.fresh?(response)
            render json: { history: history }
            return
          end

          poll_only = params[:section] == "poll"
          fresh_when(etag: [ repository.id, ::Job.where(repository_id: repository.id).maximum(:updated_at), resolution.filter.to_h, params[:stage], params[:page] ])
          return if request.fresh?(response)
          static_payload = poll_only ? {} : {
            **(history ? { history: history } : {}),
            repository: { id: repository.id, slug: repository.slug },
            tabs: repository_tabs_json(repository),
            active_smart_folder_id: active_folder&.id,
            filter_schema: ::Filters::Schema.for(subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Current.user),
            smart_folders: ::Admin::SmartFolderNavigation.new(
              subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Current.user, active_folder: active_folder,
              base_scope: ::Job.visible_to(Current.user).where(repository_id: repository.id),
              filter_class: ::SdlcPipeline::Filter, path_context: { repository_id: repository.id }
            ).folders
          }
          render json: projection.merge(static_payload)
        end
      end
    end
  end
end
