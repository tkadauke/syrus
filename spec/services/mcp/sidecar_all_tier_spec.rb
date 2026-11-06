require "rails_helper"

RSpec.describe Mcp::Sidecar, ".chat_tools tier resolution" do
  let(:chat_session) { ChatSession.create!(user: Factories.user) }

  def names(tier)
    described_class.chat_tools(chat_session, tier: tier).map { |tool| McpToolRegistry.tool_name_for(tool).to_s }
  end

  # The regression: `:all` resolved to `:essential`, which dropped every
  # deferred tool. The pending-action executor rebuilds an approved tool's
  # callable through this path, so a deferred tool could be offered, called
  # and approved, then fail replay with "tool is no longer available to this
  # actor" -- which is what operators saw after approving read_chat_messages.
  it "includes deferred tools, not just essential ones" do
    deferred = McpToolRegistry.tools(surface: :chat, tier: :deferred)
      .map { |tool| McpToolRegistry.tool_name_for(tool).to_s }
    expect(deferred).to include("read_chat_messages"), "fixture assumption: read_chat_messages is deferred"

    expect(names(:all)).to include("read_chat_messages")
  end

  it "is a superset of the essential tier" do
    expect(names(:all)).to include(*names(:essential))
  end

  it "still narrows when a concrete tier is asked for" do
    expect(names(:essential)).not_to include("read_chat_messages")
  end
end
