module Api
  module V1
    module Admin
      # Mirror of Admin::TranscriptsController for programmatic
      # access. Same parser, same captured agent-session data, JSON
      # shape suitable for piping into jq.
      #
      #   GET /api/v1/admin/runs/:run_id/transcript        → { summary, events }
      #   GET /api/v1/admin/runs/:run_id/transcript/raw    → raw JSONL
      #
      # Events are paginated (?page=N&per=K) — a 600KB JSONL can
      # produce hundreds of events and we don't want to ship the
      # whole stream every call.
      class TranscriptsController < BaseController
        DEFAULT_PER_PAGE = 100
        MAX_PER_PAGE     = 500

        def show
          run = Run.find(params[:run_id])
          session = run.claude_session
          unless session
            render_error("not_found", "No agent session captured for Run ##{run.id}.", status: :not_found)
            return
          end

          transcript = ClaudeTranscript.new(session.transcript_jsonl)
          all_events = transcript.events.to_a
          page  = [ params.fetch(:page, 1).to_i, 1 ].max
          per   = [ [ params.fetch(:per, DEFAULT_PER_PAGE).to_i, 1 ].max, MAX_PER_PAGE ].min
          slice = all_events.slice((page - 1) * per, per) || []

          render json: {
            run_id: run.id,
            session_id: session.session_id,
            summary: serialize_summary(transcript.summary),
            pagination: {
              page: page,
              per: per,
              total_events: all_events.size,
              total_pages: [ (all_events.size.to_f / per).ceil, 1 ].max
            },
            events: slice.map { |e| serialize_event(e) }
          }
        end

        def raw
          run = Run.find(params[:run_id])
          session = run.claude_session
          unless session
            render_error("not_found", "No agent session captured for Run ##{run.id}.", status: :not_found)
            return
          end
          send_data session.transcript_jsonl,
                    filename: "run-#{run.id}-#{session.session_id}.jsonl",
                    type: "application/jsonl"
        end

        private

        def serialize_summary(summary)
          {
            session_id:               summary.session_id,
            model:                    summary.model,
            cwd:                      summary.cwd,
            total_turns:              summary.total_turns,
            total_tool_calls:         summary.total_tool_calls,
            total_cost_usd:           summary.total_cost_usd,
            exit_reason:              summary.exit_reason,
            tool_call_counts:         summary.tool_call_counts,
            mcp_tool_called:          summary.mcp_tool_called?,
            available_tools_at_init:  summary.available_tools_at_init
          }
        end

        def serialize_event(event)
          { kind: event.kind.to_s, timestamp: event.timestamp, data: event.data }
        end
      end
    end
  end
end
