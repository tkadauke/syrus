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
        def show
          result = payload.show(params[:run_id])
          if result[:error]
            render_error(result.dig(:error, :code), result.dig(:error, :message), status: result[:status])
            return
          end

          render json: result
        end

        def raw
          run = Run.find(params[:run_id])
          session = run.claude_session
          unless session
            render_error("not_found", I18n.t("api.admin_transcripts.no_session", id: run.id), status: :not_found)
            return
          end
          send_data session.transcript_jsonl,
                    filename: "run-#{run.id}-#{session.session_id}.jsonl",
                    type: "application/jsonl"
        end

        private

        def payload
          ::Admin::Transcripts::Payload.new(params: params)
        end
      end
    end
  end
end
