module Api
  module V1
    module App
      class PerformanceEventsController < BaseController
        def create
          PerformanceLogging.record_browser_trace(performance_event_params)
          head :accepted
        end

        private

        def performance_event_params
          params.require(:performance_event).permit(
            :trace_id,
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
