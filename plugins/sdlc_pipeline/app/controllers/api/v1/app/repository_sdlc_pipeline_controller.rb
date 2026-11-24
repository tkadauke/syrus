module Api
  module V1
    module App
      class RepositorySdlcPipelineController < Syrus::Host::AppController
        def show
          repository = Syrus::Host::RepositoryRecord.accessible_to(Syrus::Host::Current.user).find(params[:repository_id])
          Syrus::Host::SmartFolder.ensure_builtins_for_subject!(::SdlcPipeline::SmartFolders::SUBJECT)
          active_folder = Syrus::Host::SmartFolderNavigation.active_folder(
            subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Syrus::Host::Current.user, params: params
          )
          resolution = Syrus::Host::Filters::SmartFolderResolution.call(
            filter_class: ::SdlcPipeline::Filter, subject: ::SdlcPipeline::SmartFolders::SUBJECT,
            params: params, active_smart_folder: active_folder, user: Syrus::Host::Current.user
          )
          history_only = params[:history] == "only" || params[:section] == "history-only"
          projection = !history_only && ::SdlcPipeline::Projection.new(
            repository: repository,
            user: Syrus::Host::Current.user,
            filter: resolution.filter,
            stage: params[:stage],
            page: params[:page] || 1,
            limit: params[:limit] || ::SdlcPipeline::Projection::PAGE_DEFAULT
          ).call
          history = if history_only || params[:history] == "1"
            ::SdlcPipeline::History.new(
              repository: repository, user: Syrus::Host::Current.user, filter: resolution.filter,
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
          fresh_when(etag: [ repository.id, Syrus::Host::JobRecord.visible_to(Syrus::Host::Current.user).where(repository_id: repository.id).maximum(:updated_at), resolution.filter.to_h, params[:stage], params[:page] ])
          return if request.fresh?(response)
          static_payload = poll_only ? {} : {
            **(history ? { history: history } : {}),
            repository: { id: repository.id, slug: repository.slug },
            active_smart_folder_id: active_folder&.id,
            filter_schema: Syrus::Host::Filters::Schema.for(subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Syrus::Host::Current.user),
            smart_folders: Syrus::Host::SmartFolderNavigation.new(
              subject: ::SdlcPipeline::SmartFolders::SUBJECT, user: Syrus::Host::Current.user, active_folder: active_folder,
              base_scope: Syrus::Host::JobRecord.visible_to(Syrus::Host::Current.user).where(repository_id: repository.id),
              filter_class: ::SdlcPipeline::Filter, path_context: { repository_id: repository.id }
            ).folders
          }
          render json: projection.merge(static_payload)
        end
      end
    end
  end
end
