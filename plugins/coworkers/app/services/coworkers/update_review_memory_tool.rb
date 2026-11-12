require "mcp"

class Coworkers::UpdateReviewMemoryTool < MCP::Tool
  tool_name "update_coworker_review_memory"
  description "Updates one curated Markdown memory file in the selected coworker review workspace."
  input_schema(properties: {
    path: { type: "string", description: "An approved memory/<name>.md path." },
    content: { type: "string", description: "Complete Markdown file content." }
  }, required: %w[path content])

  class << self
    def call(path:, content:, server_context:)
      run = Mcp::Tools.run_from_context(server_context)
      context = McpToolContext.from_run(run)
      return Mcp::Tools.not_authorized unless context.role == AgentRole::WORKFLOW_COWORKER_REVIEWER
      reviewer = Coworkers::ReviewContextContributor.reviewer_for(run)
      return Mcp::Tools.invalid("coworker review context is unavailable") unless reviewer
      relative = reviewer.update_review_memory!(run:, path:, content: Mcp::Tools.utf8(content))
      MCP::Tool::Response.new([ { type: "text", text: "Updated #{relative}." } ])
    end
  end
end
