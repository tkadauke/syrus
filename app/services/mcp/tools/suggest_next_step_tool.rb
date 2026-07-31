require "mcp"

module Mcp::Tools
  class SuggestNextStepTool < MCP::Tool
    tool_name "suggest_next_step"

    description <<~DESC
      Suggest the operator's most likely next message. The suggestion is
      shown as tab-completable ghost text in the chat composer, so write
      it in the operator's voice (e.g. "Create an Epic from these
      findings"). Call this at most once, at the end of a turn, and only
      when one clear next step exists.
      Do not suggest UI actions the operator must take in the Syrus interface
      (e.g. "Confirm the job", "Approve the proposal") — only suggest messages the agent can respond to in chat.
    DESC

    input_schema(
      properties: {
        text: {
          type: "string",
          description: "Concise, actionable next message in the operator's voice. " \
                       "Do not suggest UI actions the operator must take in the Syrus interface " \
                       "(e.g. \"Confirm the job\", \"Approve the proposal\") — only suggest messages " \
                       "the agent can respond to in chat. " \
                       "Stored suggestions are truncated to #{ChatSession::SUGGESTED_NEXT_STEP_MAX_BYTES} bytes " \
                       "(#{ChatSession::SUGGESTED_NEXT_STEP_MAX_BYTES} plain ASCII characters; fewer when the " \
                       "text uses accented characters or emoji, which take multiple bytes each)."
        }
      },
      required: %w[text]
    )

    class << self
      def call(text:, server_context:)
        chat_session = server_context.fetch(:chat_session)

        stored = chat_session.record_suggested_next_step!(text)
        return Mcp::Tools.invalid("text is required") if stored.blank?

        Mcp::Tools.success(
          session_id: chat_session.id,
          suggested_next_step: stored
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
