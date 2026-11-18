# frozen_string_literal: true

require "rspec/core"

module ConnectedAccounts
  module ProviderTestKit
    module_function

    def validate!(provider_class:, declaration:)
      declaration.validate!
      declaration.capabilities.each do |capability|
        raise ArgumentError, "provider must implement #{capability}" unless provider_class.respond_to?(capability)

        parameters = provider_class.method(capability).parameters
        unless parameters.length == 1 && %i[req opt].include?(parameters.first.first)
          raise ArgumentError, "provider #{capability} must accept one context object"
        end
      end
      true
    end
  end
end

RSpec.shared_examples "a connected accounts provider" do
  it "conforms to its manifest declaration" do
    expect {
      ConnectedAccounts::ProviderTestKit.validate!(
        provider_class: provider_class, declaration: provider_declaration
      )
    }.not_to raise_error
  end

  ConnectedAccounts::Provider::REQUIRED_CAPABILITIES.each do |capability|
    it "implements #{capability} with one context argument" do
      method = provider_class.method(capability)
      expect(method.parameters.length).to eq(1)
      expect(method.parameters.first.first).to satisfy { |kind| %i[req opt].include?(kind) }
    end
  end

  it "implements every optional capability it declares" do
    optional = provider_declaration.capabilities & ConnectedAccounts::Provider::OPTIONAL_CAPABILITIES
    expect(optional).to all(satisfy { |capability| provider_class.respond_to?(capability) })
  end
end
