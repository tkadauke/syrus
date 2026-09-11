module Api
  module V1
    module App
      module Admin
        # Admin-wide agent sessions feed: every agentic Run on the instance,
        # regardless of the admin's own repository memberships. `#artifacts`
        # exists because the admin surface can list sessions on repositories
        # the admin has no membership on, so it can't reuse the
        # repository-ownership-scoped `jobs#run_artifacts` route the way the
        # operator surface does. It shares ::App::RunArtifactsPayload with
        # that route so the two payload shapes (feeding the same
        # RunTranscriptLogs component) can't silently drift apart -- only the
        # authorization/lookup path differs, not the JSON shape.
        class AgentActivityController < BaseController
          def sessions
            filter = current_filter
            result = ::AgentActivity::SessionsQuery.call(
              scope: :admin,
              user: Current.user,
              filter: filter,
              page: params[:page],
              per: params[:per]
            )

            render json: {
              sessions: result[:rows].map { |agent| serialize(agent) },
              total: result[:total],
              page: result[:page],
              per: result[:per],
              running_count: result[:running_count],
              filter: filter.to_h,
              filter_schema: ::AgentActivity::Filter.schema,
              active_smart_folder_id: active_smart_folder&.id,
              smart_folders: smart_folders(:admin)
            }
          end

          def artifacts
            run = Run.includes(:job, step: :workflow).find_by(id: params[:run_id])
            unless run
              render_error("not_found", "Run not found.", status: :not_found)
              return
            end

            render json: ::App::RunArtifactsPayload.build(run: run)
          end

          private

          def current_filter
            @current_filter ||= ::AgentActivity::Filter.from_params(params, smart_folder: active_smart_folder, user: Current.user)
          end

          def active_smart_folder
            @active_smart_folder ||= begin
              explicit_folder = ::Admin::SmartFolderNavigation.active_folder(
                subject: ::AgentActivity::SmartFolders::SUBJECT,
                user: Current.user,
                params: params
              )
              explicit_folder || default_smart_folder
            end
          end

          def smart_folders(scope)
            ::SmartFolder.ensure_builtins_for_subject!(::AgentActivity::SmartFolders::SUBJECT)
            ::Admin::SmartFolderNavigation.new(
              subject: ::AgentActivity::SmartFolders::SUBJECT,
              user: Current.user,
              active_folder: active_smart_folder,
              base_scope: ::AgentActivity::SessionsQuery.visible_relation(scope: scope, user: Current.user),
              filter_class: ::AgentActivity::Filter
            ).folders.map do |folder|
              folder.merge(path: folder.fetch(:path).sub(%r{\A/agent_activity}, "/admin/agent_activity"))
            end
          end

          def serialize(agent)
            ::AgentActivity::SessionSerializer.call(
              agent,
              scope: :admin
            )
          end

          def default_smart_folder
            return if smart_folder_param_present?
            return if params[::Filters::QueryParam::PARAM_NAME].present?

            ::AgentActivity::SmartFolders.default_folder
          end

          def smart_folder_param_present?
            params.key?(:smart_folder_id) || params.key?("smart_folder_id")
          end
        end
      end
    end
  end
end
