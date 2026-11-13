module Api
  module V1
    module App
      module Admin
        class TranscriptsController < BaseController
          def show
            result = ::Admin::Transcripts::Payload.new(params: params).show(params[:run_id])
            if result[:error]
              render_error(result.dig(:error, :code), result.dig(:error, :message), status: result[:status])
              return
            end

            if params[:after_event].present? && result.dig(:pagination, :total_events) == params[:after_event].to_i
              head :not_modified
            else
              render json: result
            end
          end

          def event
            result = ::Admin::Transcripts::Payload.new(params: params).event(params[:run_id], params[:event_index])
            if result[:error]
              render_error(result.dig(:error, :code), result.dig(:error, :message), status: result[:status])
            else
              render json: result
            end
          end
        end
      end
    end
  end
end
