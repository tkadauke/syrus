require "rails_helper"

# Coworker authority comes from the unified permission evaluator; the old
# per-grant approval-policy map and thread-local approval bypass are gone.
RSpec.describe "removed bespoke coworker permission paths" do
  it "no longer exposes a capability approval policy map on McpToolContext" do
    expect(McpToolContext.instance_methods).not_to include(:capability_approval_policies)
    expect { McpToolContext.new(surface: :run, role: AgentRole::COWORKER, user: nil, capability_approval_policies: {}) }
      .to raise_error(ArgumentError, /capability_approval_policies/)
  end

  it "no longer offers a coworker approval bypass helper" do
    expect(Mcp::Tools::AuthorizationSupport).not_to respond_to(:with_coworker_approval_bypass)
  end
end
