# frozen_string_literal: true

require_dependency "permissions/capability_descriptor"
require_dependency "permissions/capability_upgrade_validator"
require_dependency "permissions/invocation_classifier"

module Permissions
  # Shared, behavior-oriented conformance tests for permission providers.
  # Adapters must exercise the plugin's real lookup and installation paths;
  # returning hand-built answers is not conformance.
  module ProviderTestKit
    CONTRACT_VERSION = "1.0"

    class << self
      def define_examples(rspec, adapter:)
        rspec.describe "Permissions::PermissionProvider contract v#{CONTRACT_VERSION}" do
          let(:contract_adapter) { adapter.respond_to?(:call) ? adapter.call(self) : adapter }
          let(:permission_provider) { contract_adapter.provider }

          it "declares complete capability descriptors" do
            descriptors = permission_provider.permission_capability_descriptors
            expect(descriptors).not_to be_empty
            expect(descriptors).to all(be_a(CapabilityDescriptor))
            operations = descriptors.map(&:operation)
            expect(operations).to eq(operations.uniq), "permission operations must be unique"

            descriptors.each do |descriptor|
              expect(descriptor.defaults.keys).to contain_exactly(*descriptor.requestable_roles),
                "#{descriptor.operation} must declare exactly one default for every requestable role"
              registered_scope = permission_provider.permission_resource_scopes[descriptor.resource_scope.type]
              expect(registered_scope).to equal(descriptor.resource_scope),
                "#{descriptor.operation} must reference a resource scope registered by the provider"
            end
          end

          it "normalizes fingerprints deterministically and idempotently" do
            permission_provider.permission_capability_descriptors.each do |descriptor|
              arguments = contract_adapter.fingerprint_arguments(descriptor)
              first = descriptor.normalize_fingerprint(arguments)
              expect(descriptor.normalize_fingerprint(arguments)).to eq(first),
                "#{descriptor.operation} returned different fingerprints for the same arguments"
              expect(descriptor.normalize_fingerprint(first)).to eq(first),
                "#{descriptor.operation} fingerprint normalization is not idempotent"
            end
          end

          it "redacts every declared sensitive argument" do
            permission_provider.permission_capability_descriptors.each do |descriptor|
              probe = contract_adapter.redaction_probe(descriptor)
              serialized = JSON.generate(descriptor.redact(probe.fetch(:arguments)))
              probe.fetch(:sensitive_values).each do |secret|
                expect(serialized).not_to include(secret.to_s),
                  "#{descriptor.operation} redaction leaked a sensitive probe value"
              end
            end
          end

          it "does not distinguish hidden resources from unknown resources" do
            permission_provider.permission_resource_scopes.each_value do |schema|
              probe = contract_adapter.visibility_probe(schema)
              hidden = schema.lookup(probe.fetch(:hidden_identifier), context: probe.fetch(:context))
              unknown = schema.lookup(probe.fetch(:unknown_identifier), context: probe.fetch(:context))

              expect(hidden).to eq(unknown),
                "#{schema.type} lookup reveals whether a resource exists outside caller visibility"
              expect(hidden.status).to eq(:not_found),
                "#{schema.type} hidden and unknown lookups must both return not_found"
            end
          end

          it "falls back to the descriptor's maximum classification on uncertainty" do
            permission_provider.permission_capability_descriptors.each do |descriptor|
              result = InvocationClassifier.call(
                descriptor: descriptor,
                arguments: contract_adapter.uncertain_arguments(descriptor)
              )

              expect(result).to be_fallback,
                "#{descriptor.operation} uncertainty must trigger the maximum-risk fallback"
              expect(result.to_h).to include(
                operation: descriptor.operation, effects: descriptor.effects, risk: descriptor.risk
              )
            end
          end

          it "enforces provider and resource ceilings" do
            expect(contract_adapter.verify_ceiling_enforcement!).to be(true),
              "a lower-layer allow overrode a non-delegable provider or resource ceiling"
          end

          it "accounts for identifier and scope migrations" do
            expect do
              permission_provider.validate_permission_upgrade!(
                previous_descriptors: contract_adapter.previous_descriptors
              )
            end.not_to raise_error
          end

          it "installs and enables without granting authority" do
            before = contract_adapter.authority_snapshot
            contract_adapter.install_and_enable!
            expect(contract_adapter.authority_snapshot).to eq(before),
              "plugin installation or enablement created permission authority"
          end
        end
      end
    end
  end
end
