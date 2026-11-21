require "rails_helper"

RSpec.describe Permissions::WorkflowActions do
  let(:workflow_entries) { McpToolRegistry.entries(surface: :workflow).index_by(&:tool_name) }
  let(:insight_entries) { McpToolRegistry.entries(surface: :agent_insight).index_by(&:tool_name) }

  it "replaces the complete core workflow and insight compatibility inventories" do
    expect(workflow_entries.size).to eq(37)
    expect(insight_entries.keys).to contain_exactly("read_live_state", "read_run_worker_health")
    expect(workflow_entries.values + insight_entries.values).to all(
      have_attributes(explicit_descriptor: true)
    )
  end

  it "covers every workflow registration with a certain classification" do
    expect(workflow_entries.keys - described_class.tool_names - Permissions::EffectActions.tool_names).to be_empty

    workflow_entries.each_value do |entry|
      expect(entry.descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "keeps read operations allowed and caps mutations at invocation authority" do
    workflow_entries.each_value do |entry|
      descriptor = entry.descriptor
      if entry.tool_name == "submit_artifact"
        expect(descriptor.defaults.values.uniq).to eq([ :allow ])
        expect(descriptor.maximum_autonomy).to eq(:permanent)
      elsif entry.mutation
        expect(descriptor.defaults.values.uniq).to eq([ :ask ])
        expect(descriptor.maximum_autonomy).to eq(:permanent)
      else
        expect(descriptor.defaults.values.uniq).to eq([ :allow ])
        expect(descriptor.maximum_autonomy).to eq(:permanent)
      end
    end
  end

  it "shares observer contracts with agent insights without widening surface access" do
    insight_entries.each do |name, insight_entry|
      workflow_entry = workflow_entries.fetch(name)

      expect(insight_entry.descriptor.contract_key).to eq(workflow_entry.descriptor.contract_key)
      expect(insight_entry.descriptor.operation).to eq(workflow_entry.descriptor.operation)
      expect(insight_entry.descriptor.requestable_roles).to include(AgentRole::AGENT_INSIGHT)
    end
  end

  it "has no validation findings for the migrated core surfaces" do
    registrations = Permissions::CapabilityRegistryValidator.for_application.registrations.select do |registration|
      registration.source == "core" && registration.surface.in?(%i[workflow agent_insight])
    end

    validator = Permissions::CapabilityRegistryValidator.new(registrations)
    expect(validator.findings).to be_empty
  end

  it "drives authorization decisions from every migrated descriptor" do
    (workflow_entries.values + insight_entries.values).each do |entry|
      role = entry.descriptor.requestable_roles.first
      decision = Permissions::PolicyEvaluator.new(
        descriptor: entry.descriptor, role:, resource_scope: {}, rules: [], context: {}, arguments: {}
      ).call

      # Essential workflow output (summaries, reviews, reports) is always
      # allowed; the remaining mutations ask.
      expected = entry.mutation && entry.tool_name != "submit_artifact" && !entry.descriptor.essential? ? :ask : :allow
      expect(decision.policy).to eq(expected)
    end
  end
end
