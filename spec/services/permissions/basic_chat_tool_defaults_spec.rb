require "rails_helper"

# Operators hit an approval prompt for ordinary chat work -- bookmarking a
# topic, attaching a repository, opening another of their own chats. Two
# causes: the compatibility descriptor turned every `mutation: true` chat
# tool into `ask` regardless of what it writes, and two ingestion operations
# were declared `ask` while their siblings were `allow`.
RSpec.describe "defaults for basic chat tools" do
  def chat_defaults(name)
    entry = McpToolRegistry.entries(surface: :chat).find { |e| McpToolRegistry.tool_name_for(e.tool).to_s == name }
    raise "#{name} is not registered on the chat surface" unless entry

    (entry.descriptor.defaults || {}).values.uniq
  end

  {
    "set_bookmark" => "writes a label on the chat the operator is already in",
    "suggest_next_step" => "posts a suggestion into that same chat",
    "attach_repository" => "binds a repository the owner can already see",
    "read_chat_messages" => "reads a chat resolved through accessible_chat_sessions"
  }.each do |tool, why|
    it "allows #{tool} without asking, because it #{why}" do
      expect(chat_defaults(tool)).to eq([ :allow ])
    end
  end

  # The pairs that made the inconsistency obvious: each of these was already
  # allowed while its sibling asked.
  it "matches each tool to the sibling it was inconsistent with" do
    expect(chat_defaults("read_chat_messages")).to eq(chat_defaults("search_chats"))
    expect(chat_defaults("attach_repository")).to eq(chat_defaults("detach_repository"))
  end

  # The blanket rule is still right for genuinely consequential writes; this
  # is not a licence to allow every mutation.
  it "keeps asking for writes that leave the chat" do
    expect(chat_defaults("ingest_pull_request")).to eq([ :ask ])
  end
end
