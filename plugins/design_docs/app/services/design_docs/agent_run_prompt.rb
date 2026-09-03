require "json"

module DesignDocs
  class AgentRunPrompt
    def initialize(run:)
      @run = run
    end

    def to_s
      <<~PROMPT
        You are Syrus handling a lightweight Design Docs thread mention.

        Work only in the Design Doc thread context below. Do not write repository code,
        do not create a Syrus Job or Epic, and do not mutate canonical Design Doc Markdown.
        If the user asks for repository implementation or file work, reply that it should
        be routed through chat as a Job/Epic proposal.

        Return exactly one JSON object and no Markdown fences:
        {
          "action": "suggestion" | "comment" | "no_change",
          "summary": "short result summary",
          "comment_body": "required for comment/no_change; agent-authored thread reply",
          "suggestion": {
            "start_offset": 0,
            "end_offset": 10,
            "original_markdown": "current text in range",
            "proposed_markdown": "replacement Markdown",
            "change_summary": "short owner-facing summary"
          }
        }

        Use action "suggestion" only for a safe pending DesignDocSuggestion attached to
        the same thread. Use action "comment" for a clarifying question or redirect to
        chat proposal flow. Use "no_change" when no safe suggested change can be made.

        Context:
        #{JSON.pretty_generate(@run.context_snapshot || {})}
      PROMPT
    end
  end
end
