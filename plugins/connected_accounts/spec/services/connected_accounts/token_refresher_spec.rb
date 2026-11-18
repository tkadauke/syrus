require "rails_helper"

RSpec.describe ConnectedAccounts::TokenRefresher do
  let(:account) { instance_double(ConnectedAccounts::Account, provider_key: "example") }
  let(:payload) { { access_token: "expired" }.to_json }

  before do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
  end

  it "dispatches refresh to the provider with the matching key" do
    other = double("other provider", key: "other")
    provider = double("matching provider", key: "example")
    allow(provider).to receive(:refresh)
      .with(account: account, payload: payload)
      .and_return("replacement")
    allow(Syrus::PluginRegistry).to receive(:providers_for)
      .with("connected_accounts:provider")
      .and_return([ other, provider ])

    expect(described_class.call(account:, payload:)).to eq("replacement")
  end

  it "fails closed when no refresh-capable provider has the account key" do
    provider = double("provider without refresh", key: "example")
    allow(Syrus::PluginRegistry).to receive(:providers_for)
      .with("connected_accounts:provider")
      .and_return([ provider ])

    expect { described_class.call(account:, payload:) }
      .to raise_error(described_class::Unsupported, /does not have one token refresh provider/)
  end

  it "fails closed when multiple refresh providers claim the account key" do
    providers = 2.times.map do |index|
      double("provider #{index}", key: "example", refresh: "replacement")
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for)
      .with("connected_accounts:provider")
      .and_return(providers)

    expect { described_class.call(account:, payload:) }
      .to raise_error(described_class::Unsupported, /does not have one token refresh provider/)
  end
end
