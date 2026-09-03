require "json"

module DesignDocs
  class ApplyAgentRunOutput
    def self.call(...)
      new(...).call
    end

    def initialize(run:, raw_output:)
      @run = run
      @raw_output = raw_output.to_s
    end

    def call
      payload = parse_payload
      case payload.fetch("action").to_s
      when "suggestion" then apply_suggestion(payload)
      when "comment" then apply_comment(payload)
      when "no_change" then apply_no_change(payload)
      else raise ArgumentError, "unknown action #{payload.fetch('action').inspect}"
      end
    end

    private

    attr_reader :run, :raw_output

    def parse_payload
      text = raw_output.strip
      text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip
      JSON.parse(text)
    end

    def apply_suggestion(payload)
      suggestion_payload = payload.fetch("suggestion")
      result = DesignDocs::CreateSuggestion.call(
        design_doc: run.design_doc,
        user: run.requested_by_user,
        actor_kind: "agent",
        attributes: {
          start_offset: suggestion_payload.fetch("start_offset"),
          end_offset: suggestion_payload.fetch("end_offset"),
          original_markdown: suggestion_payload["original_markdown"],
          proposed_markdown: suggestion_payload.fetch("proposed_markdown"),
          change_summary: suggestion_payload["change_summary"],
          thread_id: run.design_doc_thread_id,
          design_doc_agent_run_id: run.id,
          triggering_comment_id: run.triggering_comment_id
        }
      )
      result.suggestion.update!(agent_run: run)
      summary = payload["summary"].presence || result.suggestion.change_summary.presence || "Created a pending suggestion."
      [ summary, payload.merge("suggestion_id" => result.suggestion.id) ]
    end

    def apply_comment(payload)
      body = payload["comment_body"].to_s.strip
      raise ArgumentError, "comment_body is required" if body.blank?

      comment = run.thread.comments.create!(
        author_kind: "agent",
        author_user: nil,
        agent_run: run,
        body: body
      )
      summary = payload["summary"].presence || "Posted an agent reply."
      [ summary, payload.merge("comment_id" => comment.id) ]
    end

    def apply_no_change(payload)
      body = payload["comment_body"].to_s.strip.presence || payload["summary"].to_s.strip.presence || "No safe suggested change can be made from this thread."
      comment = run.thread.comments.create!(
        author_kind: "agent",
        author_user: nil,
        agent_run: run,
        body: body
      )
      summary = payload["summary"].presence || "No safe suggested change."
      [ summary, payload.merge("comment_id" => comment.id, "comment_body" => body) ]
    end
  end
end
