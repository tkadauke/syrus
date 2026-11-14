require "rails_helper"

# Plugin chat tools take part in core's tool policy.
#
# The scoped-event evaluator's set is a fixed allowlist in McpToolPolicy that
# a plugin could not join, so a tool moving out of core would silently vanish
# from it. That opt-in is declarable on the definition.
RSpec.describe "plugin chat tool policy" do
  let(:user) { Factories.user }
  let(:chat) { instance_double(ChatSession) }

  def tool_set(definitions)
    Class.new do
      include Syrus::Plugin::ChatMcpToolSet

      class << self
        attr_accessor :definitions
      end

      def self.available_for?(_chat_session, tier:) = true
      def self.tool_definitions(tier:) = definitions
      def handle(_name, _params, _context) = nil
    end.tap { |klass| klass.definitions = definitions }
  end

  let(:definitions) do
    [
      { name: "plugin_read", description: "read", input_schema: {}, evaluator: true },
      { name: "plugin_fire", description: "fire", input_schema: {} },
      { name: "plugin_plain", description: "plain", input_schema: {} }
    ]
  end

  def names_for(policy)
    Mcp::Sidecar.filter_by_policy(definitions, policy).map { |d| d[:name] }
  end

  it "keeps every advertised tool for an ordinary chat" do
    expect(names_for(nil)).to eq(%w[plugin_read plugin_fire plugin_plain])
  end

  it "offers the evaluator only what opted in" do
    expect(names_for(:evaluator)).to eq(%w[plugin_read])
  end

  it "offers coworkers shared plugin tools by default with explicit exclusions" do
    definitions = [
      { name: "shared" },
      { name: "legacy_safe", coworker_safe: true },
      { name: "admin", admin_only: true },
      { name: "mode_bound", coworker_excluded: true }
    ]

    expect(Mcp::Sidecar.filter_by_policy(definitions, :coworker).map { |definition| definition[:name] })
      .to eq(%w[shared legacy_safe])
    expect(Mcp::CoworkerToolExposure.plugin_provider?(AdminMysql::ChatToolSet)).to be(false)
    expect(Mcp::CoworkerToolExposure.plugin_provider?(SyrusBrowser::ChatToolSet)).to be(false)
  end

  it "uses ordinary availability by default and names coworker-only provider exceptions centrally" do
    shared = class_double("SharedToolSet").as_stubbed_const
    allow(shared).to receive(:name).and_return("Example::SharedToolSet")
    allow(shared).to receive(:available_for?).with(chat, tier: :essential).and_return(true)
    allow(shared).to receive(:available_for_coworker?).and_return(false)

    expect(Mcp::CoworkerToolExposure.plugin_provider_available?(shared, chat, tier: :essential)).to be(true)
    expect(Mcp::CoworkerToolExposure::COWORKER_ONLY_PLUGIN_PROVIDERS).to contain_exactly(
      "Coworkers::ChatToolSet", "SyrusDev::ChatToolSet"
    )
  end

  # A tool set written before the flags existed must behave exactly as it did.
  it "treats an unflagged tool set as it did before the flags existed" do
    plain = [ { name: "a" }, { name: "b" } ]

    expect(Mcp::Sidecar.filter_by_policy(plain, nil)).to eq(plain)
    expect(Mcp::Sidecar.filter_by_policy(plain, :evaluator)).to be_empty
  end
end
