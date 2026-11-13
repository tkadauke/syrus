module Api
  module V1
    module Admin
      # Token-auth transcript API. Same parser and captured
      # agent-session data as the React app API, with a JSON shape
      # suitable for piping into jq.
      #
      #   GET /api/v1/admin/runs/:run_id/transcript        → { summary, events }
      #   GET /api/v1/admin/runs/:run_id/transcript/raw    → raw JSONL
      #
      # Events are paginated (?page=N&per=K) — a 600KB JSONL can
      # produce hundreds of events and we don't want to ship the
      # whole stream every call.
      class TranscriptsController < BaseController
        include AdminTranscriptDelivery

        def show
          result = payload.show(params[:run_id])
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
          result = payload.event(params[:run_id], params[:event_index])
          if result[:error]
            render_error(result.dig(:error, :code), result.dig(:error, :message), status: result[:status])
          else
            render json: result
          end
        end

        def raw
          run = Run.find(params[:run_id])
          session = ProviderSession.metadata_only.find_by(resumable: run)
          unless session
            render_error("not_found", I18n.t("api.admin_transcripts.no_session", id: run.id), status: :not_found)
            return
          end
          stream_transcript(session, filename: "run-#{run.id}-#{session.session_id}.jsonl")
        end

        private

        def payload
          ::Admin::Transcripts::Payload.new(params: params)
        end
      end
    end
  end
end
