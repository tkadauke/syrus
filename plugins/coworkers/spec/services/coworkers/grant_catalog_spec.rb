require "rails_helper"

RSpec.describe Coworkers::GrantCatalog do
  it "aggregates core and enabled plugin declarations" do
    expect(described_class.names).to include("syrus.read_jobs", "workspace.files")
    expect(described_class.fetch("syrus.read_jobs").tools).to include("read_job")
  end

  it "does not collect declarations from disabled providers" do
    disabled = Class.new do
      def self.coworker_grants
        [ { name: "disabled.read", label: "Disabled", description: "Disabled", maximum_policy: "auto", tools: [] } ]
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set)
      .and_return(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set) - [ disabled ])

    expect(described_class.names).not_to include("disabled.read")
  end

  it "supports owner-validated scope metadata" do
    declaration = {
      name: "database.read", label: "Database", description: "Read a database", maximum_policy: "confirm", tools: [ "read_database" ],
      scope_options: ->(user:) { [ user.id ] }, scope_label: ->(value) { "Connection #{value}" },
      valid_scope: ->(value, user:) { value == user.id }
    }
    provider = Class.new { define_singleton_method(:coworker_grants) { [ declaration ] } }
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([ provider ])
    descriptor = described_class.fetch("database.read")
    user = Factories.user

    expect(descriptor.scope_options(user: user)).to eq([ user.id ])
    expect(descriptor.scope_label(user.id)).to eq("Connection #{user.id}")
    expect(descriptor).to be_valid_scope(user.id, user: user)
  end
end
