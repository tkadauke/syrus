module Api
  module V1
    module Admin
      class ThroughputController < BaseController
        before_action :require_throughput_enabled

        # GET /api/v1/admin/throughput
        #   ?repository=123            -- numeric Repository id
        #   ?repository=owner/name     -- slug, same as other admin filters
        #   ?since=2026-08-30T00:00:00Z
        #   ?until=2026-09-06T00:00:00Z
        def show
          render json: PerformanceLogging.phase("throughput_admin_metrics", repository_id: repository_filter&.id) {
            ::Throughput::AdminMetricsPayload.new(
              repository: repository_filter,
              since: params[:since],
              until_time: params[:until]
            ).as_json
          }
        end

        private

        def require_throughput_enabled
          return if ::Throughput.enabled?

          render_error("plugin_disabled", "The throughput plugin is disabled.", status: :not_found)
        end

        def repository_filter
          return @repository_filter if defined?(@repository_filter)

          @repository_filter =
            if params[:repository].blank?
              nil
            elsif params[:repository].to_s.match?(/\A\d+\z/)
              ::Repository.find(params[:repository])
            else
              owner, name = params[:repository].to_s.split("/", 2)
              ::Repository.find_by!(owner: owner, name: name)
            end
        end
      end
    end
  end
end
