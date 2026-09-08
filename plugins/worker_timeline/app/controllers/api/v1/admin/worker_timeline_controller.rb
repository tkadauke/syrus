module Api
  module V1
    module Admin
      # Bearer-token admin API for the Worker Timeline plugin's macro
      # (multi-lane) and per-workflow waterfall data -- the same address
      # space every other operator diagnostic lives in
      # (/api/v1/admin/overview, /stuck, /queue, /processes, ...).
      #
      # This used to be a core-owned Api::V1::Timeline::* controller pair at
      # /api/v1/timeline/*, gated on admin only, with no plugin_disabled
      # guard and no frontend consumer. It has been moved here so the
      # resource is plugin-owned end to end (JOB-3303): same
      # ::Timeline::MacroQuery / ::Timeline::WorkflowWaterfallQuery services
      # the session-authenticated Api::V1::App::Admin::WorkerTimelineController
      # (browser SPA) wraps, same payload shape, now reachable with an API
      # token and gated by the plugin's own enabled flag like
      # AdminMysql::MysqlController.
      class WorkerTimelineController < BaseController
        before_action :require_worker_timeline_enabled

        def macro
          render json: ::Timeline::MacroQuery.call(
            from: params[:from],
            to: params[:to],
            repository_id: params[:repository_id],
            epic_id: params[:epic_id],
            job_id: params[:job_id],
            hostname: params[:hostname],
            status: params[:status],
            job_type: params[:job_type]
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
