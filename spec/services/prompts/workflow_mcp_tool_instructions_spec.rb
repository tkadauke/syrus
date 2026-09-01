require "rails_helper"

RSpec.describe Prompts::WorkflowMcpToolInstructions do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
  ensure
    Syrus::PluginRegistry.reset!
    SyrusClaudeAgent.register!
    SyrusCodexAgent.register!
  end

  it "asks the registered provider to format workflow MCP tool names" do
    provider = Class.new(AgentProviders::Base) do
      include Syrus::Plugin::AgentProvider

      def self.provider_key = "oracle"
      def self.display_name = "Oracle"
      def self.available? = true

      def self.mcp_tool_name(tool_name, server_name:)
        "#{provider_key}:#{server_name}:#{tool_name}"
      end
    end

    Syrus::PluginRegistry.register(
      name: "oracle_agent",
      version: "1.0.0",
      provides: { agent_provider: provider }
    )

    expect(described_class.tool_name_for("oracle", "submit_summary")).to eq("oracle:syrus-mcp-sidecar:submit_summary")
  end
end
