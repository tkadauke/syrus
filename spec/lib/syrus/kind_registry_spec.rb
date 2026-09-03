require "rails_helper"

RSpec.describe Syrus::KindRegistry do
  def provider(trigger: [], step: [])
    Class.new do
      include Syrus::Plugin::WorkflowKinds

      class_attribute :trigger_attrs, :step_attrs
      self.trigger_attrs = trigger
      self.step_attrs = step

      def self.trigger_kinds = trigger_attrs
      def self.step_kinds = step_attrs
    end
  end

  def register(klass, name: "workflow_plugin")
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", provides: { workflow_kinds: klass })
  end

  describe "trigger kinds" do
    let(:attrs) do
      { kind: "plugin_thing", template: "Initial", label: "Plugin thing",
        style: "bg-gray-100", retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure" }
    end

    it "keeps the built-in kinds when no plugin contributes" do
      expect(Workflow::TriggerKind.values).to include("initial", "auto_merge")
    end

    it "adds a plugin-contributed kind" do
      register(provider(trigger: [ attrs ]))

      expect(Workflow::TriggerKind.values).to include("plugin_thing")
      expect(Workflow::TriggerKind.label_for("plugin_thing")).to eq("Plugin thing")
      expect(Workflow::TriggerKind.runtime_role_for("plugin_thing")).to eq("infrastructure")
    end

    it "drops the kind again when the plugin is disabled" do
      register(provider(trigger: [ attrs ]))
      PluginRecord.find_or_create_by!(name: "workflow_plugin").update!(enabled: false, disableable: true)

      expect(Workflow::TriggerKind.values).not_to include("plugin_thing")
    end

    it "refuses to let a plugin shadow a built-in kind" do
      register(provider(trigger: [ attrs.merge(kind: "initial", label: "Hijacked") ]))

      expect(Workflow::TriggerKind.label_for("initial")).to eq("Initial implementation")
    end

    it "ignores a provider that raises rather than losing every kind" do
      broken = Class.new do
        include Syrus::Plugin::WorkflowKinds
        def self.trigger_kinds = raise("boom")
      end
      register(broken, name: "broken_plugin")

      expect(Workflow::TriggerKind.values).to include("initial")
    end
  end

  describe "step kinds" do
    let(:attrs) do
      { kind: "plugin_step", handler: "Prepare", label: "Plugin step", style: "bg-gray-100", agentic: false }
    end

    it "adds a plugin-contributed step kind" do
      register(provider(step: [ attrs ]))

      expect(Step::Kind.values).to include("plugin_step")
      expect(Step::Kind.fetch("plugin_step").label).to eq("Plugin step")
    end

    it "leaves the built-in step kinds intact" do
      register(provider(step: [ attrs ]))

      expect(Step::Kind.values).to include("prepare", "implement", "grader")
    end
  end
end
