require "rails_helper"

RSpec.describe Permissions::AuthorizationAdapters do
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
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:permission_provider).and_return([ provider ])
    expect(described_class.resolve("synthetic.records")).to equal(adapter)

    # Disabled and unhealthy plugins are omitted by PluginRegistry. Resolution
    # therefore fails closed without core knowing why a provider is absent.
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:permission_provider).and_return([])
    expect(described_class.resolve("synthetic.records")).to be_nil
  end

  it "rejects ambiguous action ownership" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:permission_provider).and_return([ provider, provider ])

    expect { described_class.resolve("synthetic.records") }
      .to raise_error(described_class::DuplicateAction, /more than one provider/)
  end

  it "lets the generic decision resolve plugin-owned descriptor and subject policy" do
    request = instance_double(ChatPendingAction, action: "synthetic.records", subject_id: 42)
    decision = Permissions::AuthorizationDecision.new(request:, item: double, user: double)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:permission_provider).and_return([ provider ])

    expect(decision.send(:permission_descriptor)).to equal(request)
    expect(decision.send(:subject_selector)).to eq([ "agent", request.subject_id.to_s ])
  end
end
