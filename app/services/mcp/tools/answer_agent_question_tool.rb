require "mcp"

module Mcp::Tools
  class AnswerAgentQuestionTool < MCP::Tool
    tool_name "answer_agent_question"
    description "Answer an open workflow question. The first valid answer wins and resumes its workflow step."

    input_schema(
      properties: {
        question_id: { type: "integer" },
        answers: { type: "array", minItems: 1, maxItems: 4, items: {} }
      },
      required: %w[question_id answers]
    )

    class << self
      def call(question_id:, answers:, server_context:)
        user = McpToolContext.from_server_context(server_context).owner_chat.user
        scope = AgentQuestion.active.where.not(run_id: nil).joins(run: :job).merge(Job.visible_to(user))
        question = scope.find_by(id: question_id)
        return Mcp::Tools.invalid("workflow question not found") unless question
        return Mcp::Tools.not_authorized unless JobPolicy.new(user, question.run.job).write?

        answered = question.answer!(answers: answers, answered_by: user, source: "chat_tool")
        return Mcp::Tools.invalid("question is closed or answers are invalid") unless answered

        Mcp::Tools.success(question_id: question.id, answered: true)
      end
    end
  end
end
