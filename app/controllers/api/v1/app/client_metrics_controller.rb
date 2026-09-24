module Api
  module V1
    module App
      # Ingests batched frontend-observed counter increments (see
      # ClientMetrics) -- the browser-side half of EPIC-392's
      # entity-patch/revision-gap/hidden-tab-suppression metrics, the same
      # "batch of structured events over HTTP" shape PerformanceEventsController
      # already uses for browser traces. Never fails the request over a
      # malformed or unrecognized entry: ClientMetrics.record silently drops
      # anything outside its closed enum, and this is telemetry, not a
      # correctness-critical write.
      class ClientMetricsController < BaseController
        def create
          client_metrics_params.each do |entry|
            ClientMetrics.record(name: entry[:name], resource: entry[:resource], visibility_state: entry[:visibility_state], by: entry[:by] || 1)
          end
          head :accepted
        end

        private

        def client_metrics_params
          params.require(:client_metrics).map { |entry| permit_entry(entry) }
        end

        def permit_entry(entry)
          parameters = entry.is_a?(ActionController::Parameters) ? entry : ActionController::Parameters.new(entry.to_h)
          parameters.permit(:name, :resource, :visibility_state, :by)
        end
      end
    end
  end
end
