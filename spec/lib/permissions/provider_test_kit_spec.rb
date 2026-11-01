require "rails_helper"
require "permissions/provider_test_kit"

class PermissionProviderContractAdapter
  Context = Data.define(:visible_ids)

  attr_reader :provider

  def initialize
    @provider = Class.new do
      include Syrus::Plugin::PermissionProvider

      register_resource_scope(
        :contract_account,
        lookup: ->(identifier, context:) { { id: identifier.to_i } if context.visible_ids.include?(identifier.to_i) },
        normalize: ->(scope, context:) { scope.to_h.sort_by { |key, _value| key.to_s }.to_h.transform_keys(&:to_s) }
      )
      register_capability(
        capability: "contract.accounts@v1", operation: "contract.accounts/read@v1",
        effects: %i[network_read confidential_read], risk: :medium,
        requestable_roles: [ "chat_planner" ], defaults: { chat_planner: :ask },
        maximum_autonomy: :job, authority_durations: %i[invocation job],
        resource_scope: :contract_account,
        classifier: lambda { |arguments|
          raise "uncertain" if arguments[:force_uncertain]
          { operation: "contract.accounts/read@v1" }
        },
        fingerprint_normalizer: ->(arguments) { arguments.to_h.sort_by { |key, _value| key.to_s }.to_h.transform_keys(&:to_s) },
        redactor: ->(arguments) { arguments.to_h.except(:secret, "secret") }
      )
    end
  end

  def fingerprint_arguments(_descriptor) = { z: 1, a: 2 }
  def redaction_probe(_descriptor) = { arguments: { query: "safe", secret: "contract-secret-value" }, sensitive_values: [ "contract-secret-value" ] }
  def uncertain_arguments(_descriptor) = { force_uncertain: true }
  def previous_descriptors = provider.permission_capability_descriptors
  def authority_snapshot = [ PermissionRule.count, PermissionLease.count ]
  def install_and_enable! = true

  def visibility_probe(_schema)
    { hidden_identifier: 2, unknown_identifier: 99, context: Context.new([ 1 ]) }
  end

  def verify_ceiling_enforcement!
    descriptor = provider.permission_capability_descriptors.sole
    ceiling = Permissions::PolicyRule.new(
      id: "provider-ceiling", layer: :provider, policy: :ask, source: "contract",
      capability: descriptor.capability, delegable: false
    )
    grant = Permissions::PolicyRule.new(
      id: "agent-grant", layer: :agent, policy: :allow, source: "contract",
      capability: descriptor.capability
    )
    decision = Permissions::PolicyEvaluator.new(
      descriptor: descriptor, role: "chat_planner", resource_scope: {}, rules: [ ceiling, grant ]
    ).call
    decision.ask? && decision.chain.any? { |entry| entry.status == :decisive_ceiling }
  end
end

Permissions::ProviderTestKit.define_examples(
  RSpec,
  adapter: ->(_example) { PermissionProviderContractAdapter.new }
)
