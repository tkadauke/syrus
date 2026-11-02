require "rails_helper"

RSpec.describe Syrus::Plugin::ApprovalProvider do
  let(:provider) { Class.new { include Syrus::Plugin::ApprovalProvider } }

  it "requires provider identity and a structured decision entry point" do
    expect { provider.provider_key }.to raise_error(NotImplementedError)
    expect { provider.display_name }.to raise_error(NotImplementedError)
    expect { provider.data_sharing }.to raise_error(NotImplementedError)
    expect { provider.default_guidance }.to raise_error(NotImplementedError)
    expect { provider.decide(:request) }.to raise_error(NotImplementedError)
  end

  it "is a registered plugin extension point" do
    expect(Syrus::PluginRegistry::EXTENSION_POINTS).to include(:approval_provider)
    expect(Syrus::PluginRegistry::INTERFACE_FOR.fetch(:approval_provider).call).to eq(described_class)
  end
end
