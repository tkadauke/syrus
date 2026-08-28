module Api
  module V1
    module App
      module Admin
        # Session-authenticated data API for the Worker Timeline plugin's
        # macro (multi-lane) view. This wraps the same ::Timeline::MacroQuery
        # the bearer-token-gated /api/v1/timeline/macro endpoint uses (see
        # app/services/timeline/macro_query.rb) so the browser SPA -- which
        # authenticates via session cookie, not an API token -- has a route
        # it can actually call.
        class WorkerTimelineController < BaseController
          STATUSES = %w[ queued running succeeded failed cancelled ].freeze

          before_action :require_worker_timeline_enabled

          def macro
            render json: ::Timeline::MacroQuery.call(
              from: params[:from],
              to: params[:to],
              repository_id: params[:repository_id],
              epic_id: params[:epic_id],
              job_id: params[:job_id],
              hostname: params[:hostname],
              status: params[:status]
            )
          end

          def filters
            render json: {
              repositories: Repository.active.order(:owner, :name).limit(200).map { |repository| { id: repository.id, slug: repository.slug } },
              epics: Epic.order(created_at: :desc).limit(200).map { |epic| { id: epic.id, display_number: epic.display_number, title: epic.title } },
              statuses: STATUSES,
              hostnames: InstanceVersion.where(role: "worker").distinct.order(:hostname).pluck(:hostname).compact_blank
            }
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
