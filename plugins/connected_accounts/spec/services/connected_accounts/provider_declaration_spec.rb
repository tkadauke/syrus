require "rails_helper"

RSpec.describe ConnectedAccounts::ProviderDeclaration do
  let(:provider_name) { "ConnectedAccounts::FakeProvider" }
  let(:valid_attributes) do
    {
      provider: provider_name,
      key: "example",
      display_name: "Example",
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/connected_accounts/callback/example",
      settings_notice: "Configure Example with your own client.",
      settings_notice_i18n_key: "example:settings.provider_notice",
      supports_read_only: true,
      scopes: [
        { key: "records.read", label: "Read records", risk: "low", read_only: true, syrus_capabilities: [ "records.read@v1" ] }
      ]
    }
  end

  it "accepts a complete manifest declaration" do
    declaration = described_class.build(plugin_name: "example_plugin", attributes: valid_attributes)

    expect(declaration).to have_attributes(
      plugin_name: "example_plugin", key: "example", display_name: "Example",
      callback_route: "/connected_accounts/callback/example", supports_read_only: true,
      settings_notice: "Configure Example with your own client.",
      settings_notice_i18n_key: "example:settings.provider_notice"
    )
    expect(declaration.scopes.first).to include("label" => "Read records", "risk" => "low")
    expect(declaration.read_only_scope_keys).to eq([ "records.read" ])
  end

  it "declares token entry and explicit system service identities" do
    declaration = described_class.build(plugin_name: "example_plugin", attributes: valid_attributes.merge(
      authorization_kind: "token", system_service_identities: [ "platform.telegram_delivery" ]
    ))

    expect(declaration).to be_token_authorization
    expect(declaration.system_service_identities).to eq([ "platform.telegram_delivery" ])
  end

  it "requires a binding receiver for declared system identities" do
    provider = Class.new do
      class << self
        ConnectedAccounts::Provider::REQUIRED_CAPABILITIES.each { |capability| define_method(capability) { |_context| } }
      end
    end
    stub_const("ProviderWithoutSystemBinding", provider)

    expect {
      described_class.build(plugin_name: "example_plugin", attributes: valid_attributes.merge(
        provider: "ProviderWithoutSystemBinding", system_service_identities: [ "platform.telegram_delivery" ]))
    }.to raise_error(ArgumentError, /register_system_access/)
  end

  it "requires a fixed system invocation implementation for declared system identities" do
    provider = Class.new do
      class << self
        ConnectedAccounts::Provider::REQUIRED_CAPABILITIES.each { |capability| define_method(capability) { |_context| } }
        def register_system_access(_identity, _binding) = nil
      end
    end
    stub_const("ProviderWithoutSystemInvocation", provider)

    expect {
      described_class.build(plugin_name: "example_plugin", attributes: valid_attributes.merge(
        provider: "ProviderWithoutSystemInvocation", system_service_identities: [ "platform.telegram_delivery" ]))
    }.to raise_error(ArgumentError, /system_invoke/)
  end

  it "rejects missing capabilities and malformed manifest fields" do
    attributes = valid_attributes.merge(
      key: "Not Stable", display_name: "", capabilities: %w[authorization],
      callback_route: "relative", supports_read_only: nil,
      scopes: [ { key: "records.read", label: "", risk: "surprise", syrus_capabilities: [] } ]
    )

    expect { described_class.build(plugin_name: "broken", attributes: attributes) }
      .to raise_error(ArgumentError) { |error|
        expect(error.message).to include(
          "key must be stable", "display_name is required", "missing required capabilities",
          "callback_route", "supports_read_only", "requires a label", "invalid risk",
          "requires Syrus capabilities"
        )
      }
  end

  it "requires explicit read-only membership when the provider supports read-only connections" do
    attributes = valid_attributes.deep_dup
    attributes[:scopes].first.delete(:read_only)

    expect { described_class.build(plugin_name: "broken", attributes: attributes) }
      .to raise_error(ArgumentError, /must declare read_only/)
  end

  it "rejects a provider method that does not accept exactly one context" do
    stub_const("BrokenContextProvider", Class.new do
      class << self
        def authorization(_first, _second) = nil
        def exchange_code(_context) = nil
        def refresh(_context) = nil
        def revoke(_context) = nil
        def identity(_context) = nil
        def validate(_context) = nil
      end
    end)

    expect {
      described_class.build(plugin_name: "broken", attributes: valid_attributes.merge(provider: "BrokenContextProvider"))
    }.to raise_error(ArgumentError, /must implement \.authorization\(context\)/)
  end
end
