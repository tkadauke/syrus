require "rails_helper"

RSpec.describe Syrus::Plugin::GatedToolSet do
  # A self-contained fake tool standing in for a real MCP::Tool subclass so
  # this spec doesn't depend on any specific plugin's tool classes.
  let(:fake_tool_class) do
    Class.new do
      def self.tool_name = "fake_tool"
      def self.description_value = "A fake tool"
      def self.input_schema_value = Object.new.tap { |schema| schema.define_singleton_method(:to_h) { { type: "object" } } }

      def self.call(**kwargs)
        MCP::Tool::Response.new([ { type: "text", text: kwargs.inspect } ])
      end
    end
  end

  let(:fake_plugin_module) do
    Module.new.tap { |mod| mod.define_singleton_method(:enabled?) { true } }
  end

  let(:fake_model) do
    Class.new do
      def self.exists? = true
    end
  end

  def build_chat_tool_set(plugin: fake_plugin_module, model: fake_model, label: "Fake Plugin", tool_classes:)
    Class.new do
      include Syrus::Plugin::GatedToolSet
    end.tap do |klass|
      klass.gated_by(plugin: plugin, model: model, label: label)
      klass.const_set(:TOOL_CLASSES, tool_classes)

      klass.define_singleton_method(:available_for?) do |_chat_session, tier:|
        %i[essential deferred].include?(tier.to_sym) && gated?
      end
    end
  end

  def build_workflow_tool_set(chat_tool_set, plugin: fake_plugin_module, model: fake_model)
    Class.new do
      include Syrus::Plugin::GatedToolSet
    end.tap do |klass|
      klass.gated_by(plugin: plugin, model: model, delegate_to: chat_tool_set)
    end
  end

  describe "ChatToolSet shape (no delegate_to)" do
    let(:chat_tool_set) { build_chat_tool_set(tool_classes: [ fake_tool_class ]) }

    it "exposes tool definitions from TOOL_CLASSES" do
      expect(chat_tool_set.tool_definitions(tier: :essential)).to eq(
        [ { name: "fake_tool", description: "A fake tool", input_schema: { type: "object" } } ]
      )
    end

    it "dispatches to the matching tool class with symbolized params" do
      response = chat_tool_set.new.handle("fake_tool", { "foo" => "bar" }, { ctx: 1 })

      expect(response.content.first[:text]).to eq({ foo: "bar", server_context: { ctx: 1 } }.inspect)
    end

    it "returns an error Response for an unknown tool name" do
      response = chat_tool_set.new.handle("nonexistent_tool", {}, {})

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq('Unknown Fake Plugin tool: "nonexistent_tool"')
    end

    it "rescues a raising tool and logs, returning an error Response" do
      raising_tool_class = Class.new(fake_tool_class) do
        def self.call(**) = raise ArgumentError, "boom"
      end
      klass = build_chat_tool_set(tool_classes: [ raising_tool_class ])

      expect(Rails.logger).to receive(:error).with(a_string_matching(/ArgumentError: boom/))
      response = klass.new.handle("fake_tool", {}, {})

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("ArgumentError: boom")
    end

    it "gates availability on the plugin being enabled and the model existing" do
      allow(fake_plugin_module).to receive(:enabled?).and_return(false)

      expect(chat_tool_set.available_for?(nil, tier: :essential)).to be(false)
    end

    it "gates availability on the model's existence check" do
      allow(fake_model).to receive(:exists?).and_return(false)

      expect(chat_tool_set.available_for?(nil, tier: :essential)).to be(false)
    end

    it "is available when the plugin is enabled and the model exists" do
      expect(chat_tool_set.available_for?(nil, tier: :essential)).to be(true)
    end
  end

  describe "WorkflowToolSet shape (delegate_to:)" do
    let(:chat_tool_set) { build_chat_tool_set(tool_classes: [ fake_tool_class ]) }
    let(:workflow_tool_set) { build_workflow_tool_set(chat_tool_set) }
    let(:repository) { instance_double(Repository) }
    let(:implement_context) { instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository) }
    let(:other_context) { instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository) }

    it "is available for a bare repository the same way the delegate is gated" do
      expect(workflow_tool_set.available_for?(repository)).to be(true)

      allow(fake_model).to receive(:exists?).and_return(false)
      expect(workflow_tool_set.available_for?(repository)).to be(false)
    end

    it "is available for the implement role context" do
      expect(workflow_tool_set.available_for_context?(implement_context)).to be(true)
    end

    it "is unavailable for a non-implement role context" do
      expect(workflow_tool_set.available_for_context?(other_context)).to be(false)
    end

    it "forwards tool_definitions to the delegate for the implement role" do
      expect(workflow_tool_set.tool_definitions(context: implement_context)).to eq(chat_tool_set.tool_definitions(tier: :essential))
    end

    it "returns no tool definitions for a non-implement role context" do
      expect(workflow_tool_set.tool_definitions(context: other_context)).to eq([])
    end

    it "delegates handle to the ChatToolSet instance" do
      response = workflow_tool_set.new.handle("fake_tool", { "foo" => "bar" }, {})

      expect(response.content.first[:text]).to eq({ foo: "bar", server_context: {} }.inspect)
    end
  end
end
