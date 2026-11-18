module Api
  module V1
    module App
      module Admin
        class QueueController < BaseController
          TABS = %w[active pending failed recurring workers].freeze

          def show
            tab = params[:tab].to_s
            return render_error("not_found", "Unknown queue tab: #{tab}", status: :not_found) unless TABS.include?(tab)

            with_queue_tables do
              payload = ::Admin::Queue::Payload.new(params: params, user: Current.user).public_send(tab)
              render json: payload.merge(plugin_queues: ::Admin::PluginQueueStats.call)
            end
          end

          def reap_stale_runs
            result = ::Admin::ReapStaleRuns.call(source: "Api::V1::App::Admin::QueueController")
            render json: {
              ok: true,
              message: result.message,
              issues_count: result.issues_count,
              repairs_count: result.repairs_count
            }
          end

          private

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
end
