require "rails_helper"

# Plugin chat tools take part in core's tool policy.
#
# Plugin tools are appended after core's supervisor filter runs, so before
# this a plugin tool was always offered in Supervisor chats however dangerous
# it was; and the scoped-event evaluator's set is a fixed allowlist in
# McpToolPolicy that a plugin could not join, so a tool moving out of core
# would silently vanish from it. Both are now declarable on the definition.
RSpec.describe "plugin chat tool policy" do
  let(:user) { Factories.user }

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
      { name: "plugin_fire", description: "fire", input_schema: {}, supervisor_excluded: true },
      { name: "plugin_plain", description: "plain", input_schema: {} }
    ]
  end

  def names_for(policy)
    Mcp::Sidecar.filter_by_policy(definitions, policy).map { |d| d[:name] }
  end

  it "keeps every advertised tool for an ordinary chat" do
    expect(names_for(nil)).to eq(%w[plugin_read plugin_fire plugin_plain])
  end

  it "drops supervisor-excluded tools in a Supervisor chat" do
    expect(names_for(:supervisor)).to eq(%w[plugin_read plugin_plain])
  end

  it "offers the evaluator only what opted in" do
    expect(names_for(:evaluator)).to eq(%w[plugin_read])
  end

  it "accepts string keys, since a definition may come from a plugin's JSON" do
    string_keyed = [ { "name" => "x", "supervisor_excluded" => true } ]

    expect(Mcp::Sidecar.filter_by_policy(string_keyed, :supervisor)).to be_empty
  end

  # A tool set written before the flags existed must behave exactly as it did.
  it "treats an unflagged tool set as it did before the flags existed" do
    plain = [ { name: "a" }, { name: "b" } ]

    expect(Mcp::Sidecar.filter_by_policy(plain, :supervisor)).to eq(plain)
    expect(Mcp::Sidecar.filter_by_policy(plain, :evaluator)).to be_empty
  end
end
