require "mcp"

module SyrusMcp
  class AskOperatorTool < MCP::Tool
    tool_name "ask_operator"

    description <<~DESC
      Ask the human Syrus operator a clarifying question and then stop.
      Use this sparingly when ambiguity materially affects the design or
      implementation direction. Style preferences, plausible defaults, and
      reversible choices should be decided by the agent instead.
    DESC

    input_schema(
      properties: {
        question: {
          type: "string",
          description: "A concise question for the operator."
        },
        context: {
          type: "string",
          description: "Brief context explaining what is ambiguous and why it affects the implementation."
        }
      },
      required: %w[question context]
    )

    class << self
      def call(question:, context:, server_context:)
        run = server_context[:run].reload
        question = question.to_s.strip
        context = context.to_s.strip

        return invalid("question is required") if question.empty?
        return invalid("context is required") if context.empty?

        operator_question = ChatChannel.for(run.job.repository).send_message(
          run: run,
          text: question,
          context: { "context" => context }
        )
        SyrusMcp.write_log(run, "[mcp] ask_operator recorded OperatorQuestion ##{operator_question.id}: #{question.inspect}")

        MCP::Tool::Response.new([ { type: "text", text: "Question sent. End your turn now so Syrus can wait for the operator." } ])
      rescue ChatChannel::ConfigurationError => e
        invalid("#{e.message}. Mark this run failed with category `needs_clarification` instead.")
      end

      private

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end
    end
  end
end
