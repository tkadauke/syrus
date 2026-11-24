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

  it "applies a parity context's filtering only to contexts a participant owns" do
    probe = Class.new do
      def self.context = :probe
      def self.enabled? = true
    end
    allow(Mcp::ChatToolParity).to receive(:participants).and_return([ probe ])
    definitions = [
      { name: "shared" },
      { name: "admin", admin_only: true },
      { name: "hidden", parity_exception: { reason_code: "requires_coding_checkout", explanation: "x", owner: "o",
                                            test_ref: "spec/services/mcp/plugin_tool_policy_spec.rb", absent_from: %i[probe] } }
    ]
    admin = Factories.user(admin: true)

    expect(Mcp::Sidecar.filter_by_policy(definitions, :probe).map { |d| d[:name] }).to eq(%w[shared])
    expect(Mcp::Sidecar.filter_by_policy(definitions, :probe, user: admin).map { |d| d[:name] }).to eq(%w[shared admin])
    expect(Mcp::Sidecar.filter_by_policy(definitions, :chat).map { |d| d[:name] }).to eq(%w[shared admin hidden])
    expect(Mcp::Sidecar.filter_by_policy(definitions, nil).map { |d| d[:name] }).to eq(%w[shared admin hidden])
  end

  it "uses ordinary availability when no participant owns the context" do
    shared = class_double("SharedToolSet")
    allow(shared).to receive(:available_for?).with(chat, tier: :essential).and_return(true)

    expect(Mcp::ChatToolParity.plugin_provider_available?(shared, :coworker, chat, tier: :essential)).to be(true)
  end

  # A tool set written before the flags existed must behave exactly as it did.
  it "treats an unflagged tool set as it did before the flags existed" do
    plain = [ { name: "a" }, { name: "b" } ]

    expect(Mcp::Sidecar.filter_by_policy(plain, nil)).to eq(plain)
    expect(Mcp::Sidecar.filter_by_policy(plain, :evaluator)).to be_empty
  end
end
