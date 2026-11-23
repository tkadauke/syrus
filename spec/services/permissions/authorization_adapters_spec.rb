require "rails_helper"

RSpec.describe Permissions::AuthorizationAdapters do
  it "keeps the core decision engine independent of plugin decision classes" do
    expect(Permissions::AuthorizationDecision.superclass).to eq(Object)
  end

  let(:adapter) do
    Class.new do
      def self.permission_descriptor(request) = request
      def self.subject_selector(request) = [ "agent", request.subject_id.to_s ]
    end
  end

  let(:provider) do
    Class.new do
      class << self
        attr_accessor :adapter
        def permission_authorization_adapters = { "synthetic.records" => adapter }
      end
    end.tap { |value| value.adapter = adapter }
  end

  it "resolves adapters only from the registry's active provider set" do
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([ provider ])
    expect(described_class.resolve("synthetic.records")).to equal(adapter)

    # Disabled and unhealthy plugins are omitted by PluginRegistry. Resolution
    # therefore fails closed without core knowing why a provider is absent.
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([])
    expect(described_class.resolve("synthetic.records")).to be_nil
  end

  it "rejects ambiguous action ownership" do
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([ provider, provider ])

    expect { described_class.resolve("synthetic.records") }
      .to raise_error(described_class::DuplicateAction, /more than one provider/)
  end

  it "ignores a provider whose adapter inventory is unavailable" do
    unavailable_provider = Class.new do
      def self.permission_authorization_adapters = raise("unavailable")
    end
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers)
      .and_return([ unavailable_provider, provider ])

    expect(Rails.logger).to receive(:warn).with(/provider inventory unavailable: RuntimeError: unavailable/)
    expect(described_class.resolve("synthetic.records")).to equal(adapter)
  end

  it "lets the generic decision resolve plugin-owned descriptor and subject policy" do
    request = instance_double(ChatPendingAction, action: "synthetic.records", subject_id: 42)
    decision = Permissions::AuthorizationDecision.new(request:, item: double, user: double)
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([ provider ])

    expect(decision.send(:permission_descriptor)).to equal(request)
    expect(decision.send(:subject_selector)).to eq([ "agent", request.subject_id.to_s ])
  end

  it "preserves coworker descriptor resolution when no plugin adapter matches" do
    tool = Class.new
    descriptor = Object.new
    request = instance_double(
      ChatPendingAction,
      action: "coworker_tool_call", runtime_role: AgentRole::COWORKER_CHAT,
      payload: { "tool_name" => "read_custom_data" }, chat_session: double
    )
    catalog_entry = Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_custom_data", capability: "custom.read", ungated: false,
      tier: :essential, tool:, provider: nil
    )
    allow(Syrus::Plugin::Toolkit).to receive(:permission_providers).and_return([])
    allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog_entry)
    allow(McpToolRegistry).to receive(:entries).with(surface: :coworker)
      .and_return([ Struct.new(:tool, :descriptor).new(tool, descriptor) ])

    decision = Permissions::AuthorizationDecision.new(request:, item: double, user: double)
    expect(decision.send(:permission_descriptor)).to equal(descriptor)
  end
end
