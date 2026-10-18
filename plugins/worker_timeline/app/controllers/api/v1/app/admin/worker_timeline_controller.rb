module Api
  module V1
    module App
      module Admin
        # Session-authenticated data API for the Worker Timeline plugin's
        # macro (multi-lane) and micro (per-workflow waterfall) views. This
        # wraps the same ::Timeline::MacroQuery / ::Timeline::WorkflowWaterfallQuery
        # the bearer-token-gated /api/v1/admin/worker_timeline/* endpoints use
        # (see Api::V1::Admin::WorkerTimelineController and
        # app/services/timeline/) so the browser SPA -- which authenticates
        # via session cookie, not an API token -- has routes it can call.
        class WorkerTimelineController < BaseController
          before_action :require_worker_timeline_enabled

          def macro
            folder = active_smart_folder
            floor = ::WorkerTimeline::MacroQueryFilter.smart_folder_floor(params, folder, user: Current.user)
            filter = ::WorkerTimeline::MacroQueryFilter.from_params(params, smart_folder: floor, user: Current.user)

            payload = ::Timeline::MacroQuery.call(
              from: filter.from,
              to: filter.to,
              expression: filter,
              allowed_job_ids: ::Job.accessible_to(Current.user).select(:id)
            )
            render json: payload.merge(
              filter: filter.to_h,
              filter_schema: ::WorkerTimeline::MacroQueryFilter.schema,
              active_smart_folder_id: folder&.id,
              smart_folders: smart_folders
            )
          rescue ArgumentError => e
            Rails.logger.info("Worker Timeline rejected filter: #{e.message}")
            render_error("invalid_filter", e.message, status: :unprocessable_content)
          end

          def live
            filter = ::WorkerTimeline::LiveQueryFilter.from_params(params)

            render json: ::WorkerTimeline::LiveWorkersQuery.call(
              from: filter.from,
              to: filter.to,
              hostname: filter.hostname,
              status: filter.statuses
            ).merge(
              filter: filter.to_h,
              filter_schema: ::WorkerTimeline::LiveQueryFilter.schema
            )
          end

          def workflow
            render json: ::Timeline::WorkflowWaterfallQuery.call(workflow_id: params[:id])
          end

          private

          def active_smart_folder
            @active_smart_folder ||= ::Admin::SmartFolderNavigation.active_folder(
              subject: :worker_timeline, user: Current.user, params: params
            )
          end

          def smart_folders
            ::Admin::SmartFolderNavigation.new(
              subject: :worker_timeline, user: Current.user,
              active_folder: active_smart_folder, base_scope: ::Workflow.none,
              filter_class: ::WorkerTimeline::MacroQueryFilter,
              count_provider: ->(folder) { smart_folder_count(folder) }
            ).folders
          end

          def smart_folder_count(folder)
            filter = ::WorkerTimeline::MacroQueryFilter.from_tree(folder.filter, user: Current.user)
            result = ::Timeline::MacroQuery.call(
              from: filter.from, to: filter.to, expression: filter,
              allowed_job_ids: ::Job.accessible_to(Current.user).select(:id)
            )
            count = result[:lanes].sum { |lane| [ lane[:spans].length, 1 ].max } + result[:pending].length
            { count: [ count, ::SmartFolder::COUNT_CAP ].min, count_capped: count >= ::SmartFolder::COUNT_CAP }
          end

          def require_worker_timeline_enabled
            return if ::WorkerTimeline.enabled?

            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "worker_timeline"), status: :not_found)
          end
        end
      end
    end
  end
end
