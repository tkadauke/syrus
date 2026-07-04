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
              render json: ::Admin::Queue::Payload.new(params: params, user: Current.user).public_send(tab)
            end
          end

          def reap_stale_runs
            ReapStaleRunsJob.perform_now
            render json: { ok: true, message: I18n.t("api.admin_queue.reap_ran") }
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
