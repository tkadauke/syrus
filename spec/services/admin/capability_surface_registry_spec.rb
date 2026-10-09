require "rails_helper"

RSpec.describe Admin::CapabilitySurfaceRegistry do
  StubMcpEntry = Data.define(:capability, :tool_name, :surface, :mutation, :admin_only)

  around do |example|
    original_registry = PendingActions::REGISTRY.dup
    example.run
  ensure
    PendingActions::REGISTRY.clear
    PendingActions::REGISTRY.merge!(original_registry)
  end

  def mcp_entry(capability:, tool_name: capability, surface: :workflow, mutation: false, admin_only: false)
    StubMcpEntry.new(
      capability: capability&.to_sym,
      tool_name: tool_name.to_s,
      surface: surface,
      mutation: mutation,
      admin_only: admin_only
    )
  end

  def pending_action_class(action_key, admin_only: false)
    Class.new(PendingActions::Base) do
      action_key action_key
      admin_only! if admin_only
    end
  end

  it "describes each capability once with one decision per surface" do
    capabilities = described_class.capabilities
    keys = capabilities.map(&:key)

    expect(keys).to include("submit_summary", "cancel_job")
    expect(keys).to eq(keys.uniq)
    expect(capabilities).to all(have_attributes(decisions: include(*described_class::SURFACES)))

    submit_summary = capabilities.find { |capability| capability.key == "submit_summary" }
    expect(submit_summary.decision_for(:mcp)).to be_exposed
    expect(submit_summary.decision_for(:cli).reason).to be_present
  end

  it "fails coverage for a capability with no per-surface decision" do
    registry = described_class.new(
      mcp_entries: [ mcp_entry(capability: :stub_capability) ],
      pending_action_classes: [],
      explicit_decisions: {}
    )

    expect(registry.coverage_gaps).to contain_exactly(
      include(capability: "stub_capability", surface: :user_api),
      include(capability: "stub_capability", surface: :admin_api),
      include(capability: "stub_capability", surface: :cli)
    )
  end

  it "passes on the current reviewed surface-decision allowlist" do
    expect(described_class.coverage_gaps).to eq([])
  end

  it "fails when an allowlist entry for an open gap is removed" do
    decisions = {
      gap_action: {
        user_api: { status: "not_exposed", reason: "Not part of the user API." },
        admin_api: { status: "not_exposed", reason: "Not part of the admin API." },
        cli: { status: "not_exposed", reason: "Not part of the CLI." }
      }
    }

    registry = described_class.new(
      mcp_entries: [],
      pending_action_classes: [ pending_action_class("gap_action") ],
      explicit_decisions: decisions
    )

    expect(registry.coverage_gaps).to contain_exactly(
      include(capability: "gap_action", surface: :mcp)
    )
  end

  it "marks a capability exposed on MCP when McpToolRegistry declares it" do
    registry = described_class.new(
      mcp_entries: [ mcp_entry(capability: :shared_capability, tool_name: "submit_shared_capability", mutation: true) ],
      pending_action_classes: [],
      explicit_decisions: {
        shared_capability: {
          user_api: { status: "not_exposed", reason: "No user API endpoint." },
          admin_api: { status: "not_exposed", reason: "No admin API endpoint." },
          cli: { status: "not_exposed", reason: "No CLI command." }
        }
      }
    )

    capability = registry.capabilities.fetch(0)

    expect(capability.key).to eq("shared_capability")
    expect(capability.decision_for(:mcp)).to be_exposed
    expect(capability.decision_for(:mcp).sources).to contain_exactly(include(source: "mcp", name: "submit_shared_capability"))
  end
end

RSpec.describe "capability surface coverage inventory" do
  it "has an explicit exposure or non-exposure decision for every registered capability" do
    gaps = Admin::CapabilitySurfaceRegistry.coverage_gaps

    expect(gaps).to eq([]), "Add an exposed source or an explicit not_exposed reason in Admin::CapabilitySurfaceRegistry: #{gaps.inspect}"
  end
end
