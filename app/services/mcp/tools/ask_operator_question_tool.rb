require "mcp"

module Mcp::Tools
  class AskOperatorQuestionTool < MCP::Tool
    tool_name "ask_user_question"

    description <<~DESC
      Ask the operator 1 to 4 structured questions and park this workflow step until all are answered.
      Batch every question you can foresee into this call. Every question must state a default in the
      separate defaults array. Choice questions still accept a free-form answer. Immediately end your
      turn after calling this tool. Use report_cannot_proceed only for genuine capability gaps that an
      operator answer cannot resolve.
    DESC

    input_schema(
      properties: {
        questions: {
          type: "array", minItems: 1, maxItems: 4,
          items: {
            type: "object",
            properties: {
              question: { type: "string" },
              options: { type: "array", items: { type: "string" } },
              multiple: { type: "boolean" }
            },
            required: %w[question]
          }
        },
        defaults: { type: "array", minItems: 1, maxItems: 4, items: {}, description: "One default answer per question." }
      },
      required: %w[questions defaults]
    )

    class << self
      def call(questions:, defaults:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        normalized = AgentQuestion.normalize_questions(questions)
        return Mcp::Tools.invalid("questions must contain 1 to 4 well-formed questions") unless normalized

        policy = AgentQuestions::PolicyResolution.for(run.job)
        question = AgentQuestion.create!(
          run: run, questions: normalized, defaults: defaults, asked_at: Time.current,
          times_out_at: policy.timeout && Time.current + policy.timeout
        )
        AgentQuestionTimeoutJob.set(wait_until: question.times_out_at).perform_later(question.id) if question.times_out_at
        Mcp::Tools.write_log(run, "[mcp] workflow question ##{question.id} recorded; awaiting operator answer")
        Mcp::Tools.success(question_id: question.id, message: "Question(s) recorded. End your turn now.")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
