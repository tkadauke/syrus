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

  it "allows listing pending actions without asking because it is read-only and chat-local" do
    expect(chat_defaults("list_pending_actions")).to eq([ :allow ])
  end

  # Circular gates. An agent needed the operator's approval in order to ask
  # the operator a question, or to request a permission -- a gate nobody can
  # pass, since passing it is the thing being gated. Both are allowed on the
  # coworker surface, so the same tool behaved differently depending on which
  # agent asked.
  {
    "ask_user_question" => "asking the operator a question",
    "request_permission" => "requesting a permission"
  }.each do |tool, why|
    it "does not gate #{why}" do
      expect(chat_defaults(tool)).to eq([ :allow ])
    end
  end

  # Chat-local state: reversible, confined to the chat the operator is in,
  # touching no repository, external service or other user. These were never
  # chosen as ask; the blanket mutation rule picked it for them.
  %w[
    pin_chat unpin_chat rename_chat update_pinned_context remove_pinned_context
    submit_chat_feedback withdraw_pending_action mark_goal_completed mark_goal_blocked
  ].each do |tool|
    it "allows #{tool}, which only changes the operator's own chat" do
      expect(chat_defaults(tool)).to eq([ :allow ])
    end
  end

  # `ungated` is read by the coworker catalog and was ignored on the chat
  # surface, which is how request_permission ended up gated despite being
  # registered ungated.
  it "honours the ungated flag on the chat surface" do
    entry = McpToolRegistry.entries(surface: :chat).find { |e| McpToolRegistry.tool_name_for(e.tool).to_s == "request_permission" }

    expect(entry.ungated).to be true
    expect((entry.descriptor.defaults || {}).values.uniq).to eq([ :allow ])
  end

  # Authority changes that are not ungated keep asking.
  it "still asks before revoking a permission" do
    expect(chat_defaults("revoke_permission")).to eq([ :ask ])
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
