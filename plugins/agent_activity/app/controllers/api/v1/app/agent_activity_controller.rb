module Api
  module V1
    module App
      # Operator-scoped agent sessions feed: Jobs visible via Job.accessible_to
      # (direct/Team repository membership plus upstream repositories), plus
      # Jobs they effectively own (AgentActivity::SessionsQuery).
      class AgentActivityController < BaseController
        def sessions
          filter = current_filter
          result = ::AgentActivity::SessionsQuery.call(
            scope: :mine,
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
            smart_folders: smart_folders(:mine)
          }
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
          base_scope = ::AgentActivity::SessionsQuery.visible_relation(scope: scope, user: Current.user)
          ::Admin::SmartFolderNavigation.new(
            subject: ::AgentActivity::SmartFolders::SUBJECT,
            user: Current.user,
            active_folder: active_smart_folder,
            base_scope: base_scope,
            filter_class: ::AgentActivity::Filter,
            count_provider: ->(folder) do
              ::AgentActivity::SessionsQuery.count_for_smart_folder(base_scope, folder)
            end
          ).folders
        end

        def serialize(agent)
          ::AgentActivity::SessionSerializer.call(
            agent,
            scope: :mine
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
