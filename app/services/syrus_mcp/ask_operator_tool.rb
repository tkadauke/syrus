require "mcp"

module SyrusMcp
  class AskOperatorTool < MCP::Tool
    tool_name "ask_operator"

    description <<~DESC
      Ask the Syrus operator a question when progress is blocked on human input.
      The selected repository operator-chat channel receives the question and
      Syrus records it against the current Run, Workflow, and Job.
    DESC

    input_schema(
      properties: {
        text: {
          type: "string",
          description: "The question for the operator. Include the exact decision or information needed."
        },
        context: {
          type: "object",
          description: "Optional structured context for Syrus to render with the question."
        }
      },
      required: %w[text]
    )

    class << self
      def call(text:, server_context:, context: {})
        run = server_context[:run].reload
        question_text = text.to_s.strip
        return invalid("text is required") if question_text.empty?

        question = ChatChannel.for(run.job.repository).send_message(
          run: run,
          text: question_text,
          context: context || {}
        )

        SyrusMcp.write_log(run, "[mcp] ask_operator recorded OperatorQuestion ##{question.id}")
        MCP::Tool::Response.new([
          { type: "text", text: "Question recorded in Syrus as ##{question.id}." }
        ])
      rescue ChatChannel::ConfigurationError => e
        invalid(e.message)
      end

      private

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end
    end
  end
end
