module Api
  module V1
    module App
      class PerformanceEventsController < BaseController
        # Accepts the legacy single-event shape plus the shared browser queue's
        # batched shape. The queue flushes during idle time or via sendBeacon
        # on page hide; each event still uses the same ingestion path.
        def create
          performance_events_params.each { |event| PerformanceLogging.record_browser_trace(event) }
          head :accepted
        end

        private

        def performance_events_params
          if params[:performance_events].present?
            params.require(:performance_events).map { |event| permit_event(event) }
          else
            [ permit_event(params.require(:performance_event)) ]
          end
        end

        def permit_event(event)
          parameters = event.is_a?(ActionController::Parameters) ? event : ActionController::Parameters.new(event.to_h)
          parameters.permit(
            :trace_id,
            :parent_id,
            :interaction_id,
            :name,
            :path,
            :duration_ms,
            :visibility_state,
            metadata: {},
            api_requests: %i[name path request_id duration_ms status],
            spans: [ :name, :duration_ms, :started_at_ms, { metadata: {} } ]
          )
        end
      end
    end
  end
end
