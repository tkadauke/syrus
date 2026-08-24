require "mcp"

module Mcp::Tools
  class AskUserQuestionTool < MCP::Tool
    tool_name "ask_user_question"

    description <<~DESC
      Ask the operator up to 4 related structured questions in one call and
      park the conversation until they answer all of them. Each question is
      independently single-select (options, pick one), multi-select (options,
      multiple: true, pick any number), or free-text (omit options). Prefer
      batching related questions into one call over chaining several
      ask_user_question calls.

      After calling this tool, you MUST immediately end your turn — do not call
      any other tools or produce any further text. The operator's answers will
      start a new conversation turn, at which point you should continue the task
      using those answers.
    DESC

    input_schema(
      properties: {
        questions: {
          type: "array",
          minItems: 1,
          maxItems: 4,
          items: {
            type: "object",
            properties: {
              question: {
                type: "string",
                description: "Question text to show to the operator, rendered as Markdown. For multi-line " \
                  "questions, write an actual line break in the string — not the literal two-character " \
                  "sequence backslash-n."
              },
              options: {
                type: "array",
                items: { type: "string" },
                description: "Optional multiple-choice answers shown as buttons or checkboxes."
              },
              multiple: {
                type: "boolean",
                description: "When true, the operator may select any number of options (checkboxes). Requires options."
              }
            },
            required: %w[question]
          },
          description: "1 to 4 related questions, answered atomically as one set."
        }
      },
      required: %w[questions]
    )

    class << self
      def call(questions:, server_context:)
        chat_session = server_context.fetch(:chat_session)

        normalized_questions = normalize_questions(questions)
        return normalized_questions if normalized_questions.is_a?(MCP::Tool::Response)

        record = chat_session.agent_questions.create!(
          questions: normalized_questions,
          asked_at: Time.current
        )

        Mcp::Tools.success(
          question_id: record.id,
          message: "Question(s) recorded. You MUST end your turn now — do not call any more tools or produce any further output. The operator's answer(s) will arrive as the next message in a new conversation turn."
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      # Models occasionally write the literal two-character sequence
      # backslash-n into a tool-call string when they intend a line break,
      # instead of an actual embedded newline. The question text renders as
      # Markdown, so without this the literal escape shows up verbatim in
      # the chat UI instead of producing a line break.
      def normalize_line_breaks(text)
        text.gsub('\n', "\n")
      end

      # Returns the normalized questions array, or an Mcp::Tools.invalid
      # MCP::Tool::Response when validation fails.
      def normalize_questions(questions)
        return Mcp::Tools.invalid("questions must be an array of 1 to 4 questions") unless questions.is_a?(Array)
        return Mcp::Tools.invalid("questions must be an array of 1 to 4 questions") if questions.empty? || questions.length > 4

        questions.map do |sub_question|
          normalized = normalize_question(sub_question)
          return normalized if normalized.is_a?(MCP::Tool::Response)

          normalized
        end
      end

      def normalize_question(sub_question)
        return Mcp::Tools.invalid("each question must be an object with a question field") unless sub_question.is_a?(Hash)

        sub_question = sub_question.transform_keys(&:to_s)
        question_text = normalize_line_breaks(sub_question["question"].to_s).strip
        return Mcp::Tools.invalid("question is required") if question_text.blank?

        normalized_options = normalize_options(sub_question["options"])
        return Mcp::Tools.invalid("options must be an array of non-empty strings") if normalized_options == false

        multiple = sub_question["multiple"] ? true : false
        return Mcp::Tools.invalid("multiple-select questions require non-empty options") if multiple && normalized_options.blank?

        { "question" => question_text, "options" => normalized_options, "multiple" => multiple }
      end

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
