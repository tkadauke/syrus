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
        Use only read-only tools if more context is necessary, except for the final
        submit_scoped_event_decision tool call.

        Decide whether the event needs no visible chat activity, a visible response, or
        an action handoff to the live chat agent.

        Required output:
        - Call submit_scoped_event_decision exactly once with this schema:
        {
          "decision": "no_op" | "respond" | "act",
          "reason": "short reason",
          "urgency": 0.0,
          "confidence": 0.0,
          "handoff_prompt": "optional concise prompt for the live chat agent"
        }
        - After the tool call, return a brief confirmation only.
        - If the tool is unavailable, return one JSON object with that same schema
          and nothing else.

        Rules:
        - Use "no_op" when the event is informational, duplicate, already handled, or not relevant to the chat.
        - Use "respond" when the operator should see a concise update.
        - Use "act" only when the live chat agent should inspect state, plan a response, or recommend an operational next step.
        - "urgency" and "confidence" must be numbers from 0.0 to 1.0.
        - Include "handoff_prompt" only for respond or act.

        Success-kind events (e.g. job_implemented, pr_merged, epic_completed,
        main_recovered) need extra scrutiny: they report that
        something went *fine*, not that something needs attention. Only choose
        "respond"/"act" for a success-kind event when the chat transcript shows
        clear evidence the operator cares about hearing when this specific piece
        of work finishes -- they asked to be notified, asked a direct question
        about timing or outcome, or the event closes out something they were
        actively waiting on. Default to "no_op" for a routine successful
        completion where nothing in the chat's history suggests the operator is
        watching for it. Do not treat "the operator started this work" alone as
        evidence they are watching for its completion -- most Jobs/Epics finish
        without anyone needing a ping.

        Two contrasting examples:
        - Chat history ends with the operator saying "let me know when this
          lands" (or "ping me when it's done", "tell me once the PR merges").
          A job_implemented/pr_merged event for that same Job closes out an
          explicit ask -> "respond" (or "act" if the update should prompt a
          next step), with a short handoff_prompt confirming the outcome.
        - Chat history shows the operator confirming a proposal and then moving
          on to unrelated topics (a different Job, a design question, nothing
          further about this one). A job_implemented event later for that Job
          is routine progress nobody is watching for -> "no_op".

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
