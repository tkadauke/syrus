module Api
  module V1
    module App
      module Admin
        # Session-authenticated data API for the Worker Timeline plugin's
        # macro (multi-lane) and micro (per-workflow waterfall) views. This
        # wraps the same ::Timeline::MacroQuery / ::Timeline::WorkflowWaterfallQuery
        # the bearer-token-gated /api/v1/timeline/* endpoints use (see
        # app/services/timeline/) so the browser SPA -- which authenticates
        # via session cookie, not an API token -- has routes it can call.
        class WorkerTimelineController < BaseController
          before_action :require_worker_timeline_enabled

          def macro
            filter = ::Timeline::MacroQueryFilter.from_params(params)

            render json: ::Timeline::MacroQuery.call(
              from: filter.from,
              to: filter.to,
              repository_id: filter.repository_id,
              epic_id: filter.epic_id,
              hostname: filter.hostname,
              status: filter.status
            ).merge(
              filter: filter.to_h,
              filter_schema: ::Timeline::MacroQueryFilter.schema
            )
          end

          def workflow
            render json: ::Timeline::WorkflowWaterfallQuery.call(workflow_id: params[:id])
          end

          private

          def require_worker_timeline_enabled
            return if ::WorkerTimeline.enabled?

            render_error("plugin_disabled", "The worker_timeline plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
