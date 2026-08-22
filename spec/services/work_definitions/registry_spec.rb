require "rails_helper"

RSpec.describe WorkDefinitions do
  it "defines every non-legacy workflow trigger kind" do
    expected = Workflow::TriggerKind.values - Workflow::TriggerKind.runtime_role_values("legacy")

    expect(described_class.registry.keys).to include(*expected)
  end

  it "keeps WorkDefinition metadata in sync with Workflow::TriggerKind" do
    described_class.registry.each do |kind, definition_class|
      trigger_entry = Workflow::TriggerKind.fetch(kind)
      definition = definition_class.new

      expect(definition.kind).to eq(kind)
      expect(definition.workflow_trigger_kind).to eq(kind)
      expect(definition.runtime_role).to eq(trigger_entry.runtime_role)
      expect(definition.workflow_template).to eq(trigger_entry.template_class)
      expect(definition.scope).to be_present
    end
  end

  it "requires child workflow definitions to declare their parent kind" do
    child_definitions = described_class.registry.values.select { |definition_class| definition_class.runtime_role == "child" }

    expect(child_definitions).to all(have_attributes(parent_kind: be_present))
  end

  it "marks infrastructure workflows explicitly" do
    expect(described_class.for("main_grader")).to be_infrastructure
    expect(described_class.for("agent_insight")).to be_infrastructure
  end
end
