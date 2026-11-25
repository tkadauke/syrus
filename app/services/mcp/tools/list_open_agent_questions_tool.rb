require "mcp"

module Mcp::Tools
  class ListOpenAgentQuestionsTool < MCP::Tool
    tool_name "list_open_agent_questions"
    description "List open operator questions from workflow runs visible to the current user."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Optional Job id filter." },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "Maximum results; defaults to 20." }
      }
    )

    class << self
      def call(server_context:, job_id: nil, limit: 20)
        user = McpToolContext.from_server_context(server_context).owner_chat.user
        limit = Integer(limit, exception: false).to_i.clamp(1, 100)
        scope = AgentQuestion.active.where.not(run_id: nil).joins(run: :job).merge(Job.visible_to(user)).preload(run: :job)
        scope = scope.where(jobs: { id: job_id }) if job_id

        Mcp::Tools.success(questions: scope.limit(limit).map { |question| payload(question) })
      end

      private

      def payload(question)
        {
          id: question.id,
          job_id: question.run.job_id,
          job_title: question.run.job.issue_title,
          asked_at: question.asked_at,
          times_out_at: question.times_out_at,
          questions: question.questions_payload
        }
      end
    end
  end
end
