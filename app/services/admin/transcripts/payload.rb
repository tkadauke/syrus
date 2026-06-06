module Admin
  module Transcripts
    class Payload
      DEFAULT_PER_PAGE = 100
      MAX_PER_PAGE = 500

      def initialize(params:)
        @params = params
      end

      def show(run_id)
        run = Run.find(run_id)
        session = run.claude_session

        transcript = ClaudeTranscript.new(session&.transcript_jsonl)
        all_events = transcript.events.to_a
        all_events.concat(job_log_events(run)) if include_job_log_fallback?(session, all_events)
        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per = [ [ params.fetch(:per, DEFAULT_PER_PAGE).to_i, 1 ].max, MAX_PER_PAGE ].min
        slice = all_events.slice((page - 1) * per, per) || []

        {
          run_id: run.id,
          job_id: run.job_id,
          step_kind: run.step&.kind,
          workflow_trigger_kind: run.step&.workflow&.trigger_kind,
          session_id: session&.session_id,
          summary: serialize_summary(transcript.summary),
          pagination: {
            page: page,
            per: per,
            total_events: all_events.size,
            total_pages: [ (all_events.size.to_f / per).ceil, 1 ].max
          },
          events: slice.map { |event| serialize_event(event) }
        }
      end

      private

      attr_reader :params

      def include_job_log_fallback?(session, events)
        session.nil? ||
          session.transcript_jsonl.blank? ||
          events.empty? ||
          events.none? { |event| event.kind == :result }
      end

      def job_log_events(run)
        run.job_logs.order(:sequence).map do |log|
          ClaudeTranscript::Event.new(
            kind: :job_log,
            timestamp: log.created_at&.iso8601,
            data: {
              sequence: log.sequence,
              kind: log.kind,
              text: log.chunk
            }
          )
        end
      end

      def serialize_summary(summary)
        {
          session_id: summary.session_id,
          model: summary.model,
          cwd: summary.cwd,
          total_turns: summary.total_turns,
          total_tool_calls: summary.total_tool_calls,
          total_cost_usd: summary.total_cost_usd,
          exit_reason: summary.exit_reason,
          tool_call_counts: summary.tool_call_counts,
          mcp_tool_called: summary.mcp_tool_called?,
          available_tools_at_init: summary.available_tools_at_init
        }
      end

      def serialize_event(event)
        { kind: event.kind.to_s, timestamp: event.timestamp, data: event.data }
      end
    end
  end
end
