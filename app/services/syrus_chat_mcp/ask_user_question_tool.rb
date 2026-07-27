require "mcp"

module SyrusChatMcp
  class AskUserQuestionTool < MCP::Tool
    tool_name "ask_user_question"

    description <<~DESC
      Ask the operator a structured question in the current chat and park the
      conversation until they answer. Use options for a short multiple-choice
      question; omit options when a free-form answer is needed.

      After calling this tool, you MUST immediately end your turn — do not call
      any other tools or produce any further text. The operator's answer will
      start a new conversation turn, at which point you should continue the task
      using that answer.
    DESC

    input_schema(
      properties: {
        question: { type: "string", description: "Question text to show to the operator." },
        options: {
          type: "array",
          items: { type: "string" },
          description: "Optional multiple-choice answers shown as buttons."
        }
      },
      required: %w[question]
    )

    class << self
      def call(question:, server_context:, options: nil)
        chat_session = server_context.fetch(:chat_session)
        question_text = question.to_s.strip
        return SyrusChatMcp.invalid("question is required") if question_text.blank?

        normalized_options = normalize_options(options)
        return SyrusChatMcp.invalid("options must be an array of non-empty strings") if normalized_options == false

        record = chat_session.agent_questions.create!(
          question: question_text,
          options: normalized_options,
          asked_at: Time.current
        )

        SyrusChatMcp.success(
          question_id: record.id,
          message: "Question recorded. You MUST end your turn now — do not call any more tools or produce any further output. The operator's answer will arrive as the next message in a new conversation turn."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def normalize_options(options)
        return nil if options.nil?
        return false unless options.is_a?(Array)

        normalized = options.map { |option| option.to_s.strip }.reject(&:blank?)
        return false if normalized.empty? || normalized.length != options.length

        normalized
      end
    end
  end
end
