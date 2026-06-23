require "mcp"

module SyrusChatMcp
  class AskUserQuestionTool < MCP::Tool
    ASK_TIMEOUT_SECONDS = 300
    POLL_INTERVAL_SECONDS = 1

    tool_name "ask_user_question"

    description <<~DESC
      Ask the operator a structured question in the current chat and wait
      until they answer. Use options for a short multiple-choice question;
      omit options when a free-form answer is needed.
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

        wait_for_answer(record)
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

      def wait_for_answer(record)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ASK_TIMEOUT_SECONDS

        loop do
          record.reload
          return SyrusChatMcp.success(answer: record.answer.to_s) if record.answered_at.present?
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(POLL_INTERVAL_SECONDS)
        end

        unless record.expire!
          record.reload
          return SyrusChatMcp.success(answer: record.answer.to_s) if record.answered_at.present?
        end

        SyrusChatMcp.tool_error("Timed out waiting for operator answer.")
      end
    end
  end
end
