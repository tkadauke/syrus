module Admin
  module Transcripts
    class Payload
      DEFAULT_PER_PAGE = 100
      MAX_PER_PAGE = 500
      MAX_INLINE_EVENT_BYTES = 16.kilobytes
      EVENT_PREVIEW_BYTES = 2.kilobytes

      def initialize(params:)
        @params = params
      end

      def show(run_id)
        show_for_resumable(type: "Run", id: run_id)
      end

      def show_for_agent(agent_id)
        context = SessionContext.for_agent(Agent.find(agent_id))
        build(context)
      end

      def show_for_resumable(type:, id:)
        context = SessionContext.for_resumable(type: type, id: id)
        build(context)
      end

      def event(run_id, event_index)
        context = SessionContext.for_resumable(type: "Run", id: run_id)
        all_events, = events_for(context)
        index = Integer(event_index, exception: false)
        event = index && index >= 0 && all_events[index]
        return { error: { code: "not_found", message: "Transcript event not found" }, status: :not_found } unless event

        serialize_event(event, index: index, truncate: false)
      end

      private

      attr_reader :params

      def build(context)
        session = context.provider_session

        all_events, transcript = events_for(context)
        page = [ params.fetch(:page, 1).to_i, 1 ].max
        per = [ [ params.fetch(:per, DEFAULT_PER_PAGE).to_i, 1 ].max, MAX_PER_PAGE ].min
        after_event = Integer(params[:after_event], exception: false)
        offset = after_event ? [ after_event, 0 ].max : (page - 1) * per
        slice = all_events.slice(offset, per) || []

        {
          run_id: context.run_id,
          job_id: context.job_id,
          job_slug: context.job_slug,
          step_kind: context.step_kind,
          workflow_trigger_kind: context.workflow_trigger_kind,
          finished: context.finished?,
          session_id: session&.session_id,
          summary: serialize_summary(transcript.summary),
          pagination: {
            page: page,
            per: per,
            total_events: all_events.size,
            total_pages: [ (all_events.size.to_f / per).ceil, 1 ].max
          },
          events: slice.each_with_index.map { |event, index| serialize_event(event, index: offset + index) }
        }
      end

      def events_for(context)
        session = context.provider_session
        transcript = ClaudeTranscript.new(session&.transcript_jsonl)
        events = transcript.events.to_a
        events.concat(context.fallback_events) if context.include_fallback_events?(session, events)
        [ events, transcript ]
      end

      def serialize_summary(summary)
        {
          model: summary.model,
          total_turns: summary.total_turns,
          total_tool_calls: summary.total_tool_calls,
          total_cost_usd: summary.total_cost_usd,
          exit_reason: summary.exit_reason,
          tool_call_counts: summary.tool_call_counts,
          mcp_tool_called: summary.mcp_tool_called?
        }
      end

      def serialize_event(event, index:, truncate: true)
        data = event.data
        serialized = { index: index, kind: event.kind.to_s, timestamp: event.timestamp, data: data }
        return serialized unless truncate && data.to_json.bytesize > MAX_INLINE_EVENT_BYTES

        serialized.merge(data: preview_data(data), body_truncated: true)
      end

      def preview_data(value)
        case value
        when Hash
          value.transform_values { |child| preview_data(child) }
        when Array
          value.map { |child| preview_data(child) }
        when String
          value.bytesize > EVENT_PREVIEW_BYTES ? "#{value.safe_byteslice(0, EVENT_PREVIEW_BYTES)}…" : value
        else
          value
        end
      end

      class SessionContext
        REGISTRY = {
          "Run" => "Admin::Transcripts::Payload::RunSessionContext",
          "ChatSession" => "Admin::Transcripts::Payload::GenericSessionContext",
          "DesignDocs::DesignDocAgentRun" => "Admin::Transcripts::Payload::GenericSessionContext"
        }.freeze

        def self.for_agent(agent)
          klass = REGISTRY.fetch(agent.resumable_type, "Admin::Transcripts::Payload::GenericSessionContext").constantize
          klass.new(agent: agent, resumable: agent.resumable)
        end

        def self.for_resumable(type:, id:)
          klass_name = REGISTRY.fetch(type)
          resumable = type.constantize.find(id)
          agent = Agent.find_by(resumable: resumable) || Agent.new(resumable: resumable)

          klass_name.constantize.new(agent: agent, resumable: resumable)
        end
      end

      class GenericSessionContext
        def initialize(agent:, resumable:)
          @agent = agent
          @resumable = resumable
        end

        def provider_session = @agent.provider_session
        def agent_id = @agent.id
        def resumable_type = @agent.resumable_type || @resumable.class.name
        def resumable_id = @agent.resumable_id || @resumable.id
        def run_id = nil
        def job_id = nil
        def job_slug = nil
        def step_kind = nil
        def workflow_trigger_kind = nil
        def finished? = false
        def fallback_events = []
        def include_fallback_events?(_session, _events) = false
      end

      class RunSessionContext < GenericSessionContext
        def run_id = run.id
        def job_id = run.job_id
        def job_slug = run.job&.slug
        def step_kind = run.step&.kind
        def workflow_trigger_kind = run.step&.workflow&.trigger_kind
        def finished? = run.terminal?

        def include_fallback_events?(session, events)
          session.nil? ||
            session.transcript_jsonl.blank? ||
            events.empty? ||
            events.none? { |event| event.kind == :result }
        end

        def fallback_events
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

        private

        def run = @resumable
      end
    end
  end
end
