require "rails_helper"

# Capability authorization (Mcp::Tools::AuthorizationSupport::ToolDispatch:
# scheduled, coworker and actor approval) is installed when a tool is
# registered, not by whichever serving path first wraps it (decision NY9).
# The per-path installation let the daemon's workflow route serve gated tools
# without it, so scheduled runs skipped the owner's rules (F47), and made
# gating depend on what the process had served before (F46).
RSpec.describe "MCP tool authorization" do
  it "is installed on every registered tool once the registry is read" do
    unguarded = McpToolRegistry.entries.reject do |entry|
      entry.tool.singleton_class < Mcp::Tools::AuthorizationSupport::ToolDispatch
    end.map { |entry| "#{entry.surface}:#{entry.tool_name}" }

    expect(unguarded).to be_empty, <<~MSG
      Registered MCP tools without the capability authorization layer:
        #{unguarded.join("\n  ")}
    MSG
  end
end
