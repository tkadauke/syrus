require "json"

module Prompts
  class ChatEventEvaluator
    def initialize(chat_session:, scoped_event:, context_summary:)
      @chat_session = chat_session
      @scoped_event = scoped_event
      @context_summary = context_summary
    end

    def to_s
      <<~PROMPT
        You are evaluating whether a scoped Syrus chat event should wake this chat.

        You are running in a disposable evaluator session. Do not address the operator.
        Do not mutate state. Use only read-only tools if more context is necessary.

        Decide whether the event needs no visible chat activity, a visible response, or
        an action handoff to the live chat agent.

        Return one JSON object and nothing else:
        {
          "decision": "no_op" | "respond" | "act",
          "reason": "short reason",
          "urgency": 0.0,
          "confidence": 0.0,
          "handoff_prompt": "optional concise prompt for the live chat agent"
        }

        Rules:
        - Use "no_op" when the event is informational, duplicate, already handled, or not relevant to the chat.
        - Use "respond" when the operator should see a concise update.
        - Use "act" only when the live chat agent should inspect state, plan a response, or recommend an operational next step.
        - "urgency" and "confidence" must be numbers from 0.0 to 1.0.
        - Include "handoff_prompt" only for respond or act.

        Chat:
        #{chat_json}

        Scoped event:
        #{event_json}

        Transcript clone:
        #{JSON.pretty_generate(@context_summary)}
      PROMPT
    end

    private

    def chat_json
      JSON.pretty_generate(
        id: @chat_session.id,
        title: @chat_session.title,
        provider: @chat_session.effective_chat_provider,
        system_kind: @chat_session.system_kind,
        mode: @chat_session.mode,
        repository: @chat_session.repository&.slug
      )
    end

    def event_json
      JSON.pretty_generate(
        id: @scoped_event.id,
        source_kind: @scoped_event.source_kind,
        payload: @scoped_event.payload,
        repository_id: @scoped_event.repository_id,
        job_id: @scoped_event.job_id,
        epic_id: @scoped_event.epic_id,
        proposal_id: @scoped_event.proposal_id,
        created_at: @scoped_event.created_at&.iso8601
      )
    end
  end
end
