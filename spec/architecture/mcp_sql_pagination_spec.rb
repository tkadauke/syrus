require "rails_helper"

RSpec.describe "MCP SQL pagination" do
  PAGINATED_TOOL_PATHS = %w[
    app/services/mcp/tools/list_chats_tool.rb
    app/services/mcp/tools/list_repositories_tool.rb
    app/services/mcp/tools/read_chat_messages_tool.rb
    app/services/mcp/tools/read_run_transcript_tool.rb
    plugins/agent_insights/app/services/agent_insights/tools/list_insights_tool.rb
    plugins/agent_insights/app/services/agent_insights/tools/list_recent_workflows_tool.rb
    plugins/agent_insights/app/services/agent_insights/tools/read_insight_run_transcript_tool.rb
    plugins/operator_briefing/app/services/operator_briefing/tools/list_recent_workflows_tool.rb
  ].freeze

  it "bounds page numbers for every SQL-offset MCP tool" do
    missing_normalization = PAGINATED_TOOL_PATHS.reject do |path|
      Rails.root.join(path).read.include?("Mcp::Pagination.normalize_page")
    end

    expect(missing_normalization).to be_empty,
      "SQL-offset MCP tools must normalize pages with Mcp::Pagination: #{missing_normalization.join(', ')}"
  end
end
