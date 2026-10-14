module Api
  module V1
    module Admin
      # SolidQueue introspection for external admin API clients. All
      # queries wrapped in a
      # rescue around AR errors — dev/test single-DB setups
      # respond with `{ error: { code: "queue_unreachable" } }`
      # instead of 500ing.
      #
      #   GET  /api/v1/admin/queue/active
      #   GET  /api/v1/admin/queue/pending
      #   GET  /api/v1/admin/queue/failed[?since=ISO8601]
      #   GET  /api/v1/admin/queue/recurring
      #   GET  /api/v1/admin/queue/workers
      #   POST /api/v1/admin/queue/reap_stale_runs
      class QueueController < BaseController
        def active
          render_queue_payload(:active)
        end

        def pending
          render_queue_payload(:pending)
        end

        def failed
          render_queue_payload(:failed)
        end

        def recurring
          render_queue_payload(:recurring)
        end

        def workers
          render_queue_payload(:workers)
        end

        def reap_stale_runs
          result = ::Admin::ReapStaleRuns.call(source: "Api::V1::Admin::QueueController")
          render json: {
            ok: true,
            message: result.message,
            issues_count: result.issues_count,
            repairs_count: result.repairs_count
          }
        end

        private

        def render_queue_payload(tab)
          with_queue_tables do
            render json: ::Admin::Queue::Payload.new(params: params, user: current_api_user).public_send(tab)
          end
        end

        def with_queue_tables
          yield
        rescue ActiveRecord::StatementInvalid,
               ActiveRecord::ConnectionNotEstablished,
               ActiveRecord::ActiveRecordError => e
          render_error("queue_unreachable",
                       "SolidQueue tables unreachable from this connection: #{e.message}",
                       status: :service_unavailable)
        rescue ArgumentError => e
          render_error("invalid_filter",
                       "Invalid queue filter: #{e.message}",
                       status: :unprocessable_content)
        end
      end
    end
  end
end
