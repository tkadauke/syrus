require "rails_helper"

RSpec.describe Syrus::Plugin::GatedToolSet do
  # A self-contained fake MCP::Tool standing in for a real per-connection
  # agentic tool (ListConnectionsTool, PodsTool, ...) so this spec doesn't
  # depend on any specific plugin's tool classes existing.
  let(:fake_tool_class) do
    Class.new(MCP::Tool) do
      tool_name "fake_tool"
      description "A fake tool for spec purposes"
      input_schema(type: "object", properties: { foo: { type: "string" } })

      def self.call(server_context:, **params)
        MCP::Tool::Response.new([ { type: "text", text: params.to_json } ])
      end
    end
  end

  let(:exploding_tool_class) do
    Class.new(MCP::Tool) do
      tool_name "exploding_tool"
      description "A fake tool that always raises"
      input_schema(type: "object", properties: {})

      def self.call(server_context:)
        raise ArgumentError, "boom"
      end
    end
  end

  let(:plugin_module) { double("PluginModule", enabled?: true) }
  let(:model_class) { double("ModelClass", exists?: true) }

  def build_chat_tool_set_class(tool_classes:, plugin_module:, model_class:, tool_set_label: "Fake Tool Set")
    Class.new do
      include Syrus::Plugin::GatedToolSet
    end.tap do |klass|
      # `TOOL_CLASSES = [...]` inside this block would define the constant in
      # the spec's lexical scope, not on klass - const_set is required to
      # attach it to the anonymous host class itself.
      klass.const_set(:TOOL_CLASSES, tool_classes.freeze)
      klass.gated_by(plugin_module, model: model_class, tool_set_label: tool_set_label)
    end
  end

  describe ".available_for?" do
    it "is false when the plugin is disabled" do
      klass = build_chat_tool_set_class(
        tool_classes: [ fake_tool_class ], plugin_module: double(enabled?: false), model_class: model_class
      )

      expect(klass.available_for?(nil, tier: :essential)).to be(false)
    end

    it "is false when no connection record exists" do
      klass = build_chat_tool_set_class(
        tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: double(exists?: false)
      )

      expect(klass.available_for?(nil, tier: :essential)).to be(false)
    end

    it "is true for essential/deferred tiers once enabled with a connection" do
      klass = build_chat_tool_set_class(tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: model_class)

      expect(klass.available_for?(nil, tier: :essential)).to be(true)
      expect(klass.available_for?(nil, tier: :deferred)).to be(true)
    end

    it "is false for tiers outside essential/deferred" do
      klass = build_chat_tool_set_class(tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: model_class)

      expect(klass.available_for?(nil, tier: :evaluator)).to be(false)
    end
  end

  describe ".tool_definitions" do
    it "maps TOOL_CLASSES to name/description/input_schema hashes" do
      klass = build_chat_tool_set_class(tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: model_class)

      definitions = klass.tool_definitions(tier: :essential)

      expect(definitions.map { |tool| tool.slice(:name, :description) }).to eq([
        { name: "fake_tool", description: "A fake tool for spec purposes" }
      ])
      expect(definitions.first[:input_schema]).to include(type: "object", properties: { foo: { type: "string" } })
    end
  end

  describe "#handle" do
    it "dispatches to the matching tool class, symbolizing string-keyed params" do
      klass = build_chat_tool_set_class(tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: model_class)

      response = klass.new.handle("fake_tool", { "foo" => "bar" }, {})

      expect(response.error?).to be(false)
      expect(response.content.first[:text]).to eq({ "foo" => "bar" }.to_json)
    end

    it "returns an error Response naming the tool_set_label for an unknown tool" do
      klass = build_chat_tool_set_class(
        tool_classes: [ fake_tool_class ], plugin_module: plugin_module, model_class: model_class, tool_set_label: "Fake Tool Set"
      )

      response = klass.new.handle("nonexistent_tool", {}, {})

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq('Unknown Fake Tool Set tool: "nonexistent_tool"')
    end

    it "rescues StandardError from the tool call into an error Response and logs it" do
      klass = build_chat_tool_set_class(tool_classes: [ exploding_tool_class ], plugin_module: plugin_module, model_class: model_class)
      allow(Rails.logger).to receive(:error)

      response = klass.new.handle("exploding_tool", {}, {})

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to eq("Error: ArgumentError: boom")
      expect(Rails.logger).to have_received(:error).with(/ArgumentError: boom/)
    end
  end
end

RSpec.describe Syrus::Plugin::GatedToolSet::Workflow do
  let(:repository) { instance_double(Repository) }
  let(:plugin_module) { double("PluginModule", enabled?: true) }
  let(:model_class) { double("ModelClass", exists?: true) }

  let(:chat_tool_set_class) do
    Class.new do
      def self.tool_definitions(tier:)
        [ { name: "fake_tool", description: "desc", input_schema: {} } ]
      end

      def handle(tool_name, params, server_context)
        "handled:#{tool_name}"
      end
    end
  end

  def build_workflow_tool_set_class(plugin_module:, model_class:, chat_tool_set:)
    Class.new do
      include Syrus::Plugin::GatedToolSet::Workflow
    end.tap do |klass|
      klass.gated_by(plugin_module, model: model_class, chat_tool_set: chat_tool_set)
    end
  end

  it "includes the McpToolSet interface marker" do
    klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)

    expect(klass.ancestors).to include(Syrus::Plugin::McpToolSet)
  end

  describe ".available_for?" do
    it "is false when the plugin is disabled" do
      klass = build_workflow_tool_set_class(plugin_module: double(enabled?: false), model_class: model_class, chat_tool_set: chat_tool_set_class)

      expect(klass.available_for?(repository)).to be(false)
    end

    it "is false when no connection record exists" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: double(exists?: false), chat_tool_set: chat_tool_set_class)

      expect(klass.available_for?(repository)).to be(false)
    end

    it "is true once enabled with a connection" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)

      expect(klass.available_for?(repository)).to be(true)
    end
  end

  describe ".available_for_context?" do
    it "is true only for the implement role, once available" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)
      implement_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository)
      review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

      expect(klass.available_for_context?(implement_context)).to be(true)
      expect(klass.available_for_context?(review_context)).to be(false)
    end
  end

  describe ".tool_definitions" do
    it "delegates to the gated chat_tool_set for the implement role" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)
      implement_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository)

      expect(klass.tool_definitions(context: implement_context)).to eq([ { name: "fake_tool", description: "desc", input_schema: {} } ])
    end

    it "returns an empty array for non-implement workflow roles" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)
      review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

      expect(klass.tool_definitions(context: review_context)).to eq([])
    end

    it "delegates to the gated chat_tool_set when no context is given" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)

      expect(klass.tool_definitions).to eq([ { name: "fake_tool", description: "desc", input_schema: {} } ])
    end
  end

  describe "#handle" do
    it "delegates to a new instance of the gated chat_tool_set" do
      klass = build_workflow_tool_set_class(plugin_module: plugin_module, model_class: model_class, chat_tool_set: chat_tool_set_class)

      expect(klass.new.handle("fake_tool", {}, {})).to eq("handled:fake_tool")
    end
  end
end
