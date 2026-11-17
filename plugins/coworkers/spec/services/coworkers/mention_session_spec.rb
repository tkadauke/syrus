require "rails_helper"

RSpec.describe Coworkers::MentionSession do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:source_chat) { ChatSession.create!(user: owner, repository: repository, title: "Planning") }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-mentions",
      workspace_repo: repository.remote_url
    )
  end

  before do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Coworkers::ChatAgent.create!(chat_session: source_chat, coworker: coworker, added_by_user: owner)
  end

  def source_message(text)
    source_chat.messages.create!(role: "user", content: { "text" => text }, sender_user: owner, skip_turn_trigger: true)
  end

  it "creates one hidden native session and reuses it with only the message delta" do
    older = source_message("Earlier context")
    first = source_message("@maya-mentions first question")
    link = described_class.find_or_create!(coworker: coworker, source_chat: source_chat)
    delivered = described_class.deliver!(link: link, source_message: first)

    expect(link).to have_attributes(role: "mention", source_chat_session_id: source_chat.id)
    expect(link.chat_session.hidden_at).to be_present
    expect(delivered.extract_text_from_content).to include("Earlier context", "first question", "self-contained")

    changed = source_message("One changed message")
    second = source_message("@maya-mentions second question")
    expect(described_class.find_or_create!(coworker: coworker, source_chat: source_chat)).to eq(link)
    delta = described_class.deliver!(link: link.reload, source_message: second).extract_text_from_content
    expect(delta).to include("One changed message", "second question")
    expect(delta).not_to include(older.extract_text_from_content, first.extract_text_from_content)
  end

  it "shares exactly the roster source chat and revokes the share on removal" do
    other_chat = ChatSession.create!(user: owner, title: "Private")

    expect(coworker.received_chat_shares.pluck(:chat_session_id)).to eq([ source_chat.id ])
    expect(coworker.readable_chat_session_ids).to include(source_chat.id)
    expect(coworker.readable_chat_session_ids).not_to include(other_chat.id)

    Coworkers::ChatAgent.find_by!(chat_session: source_chat, coworker: coworker).destroy!
    expect(coworker.received_chat_shares.reload).to be_empty
  end

  it "delivers the final reply once as the coworker without waking the planner" do
    source = source_message("@maya-mentions help")
    link = described_class.find_or_create!(coworker: coworker, source_chat: source_chat)
    incoming = described_class.deliver!(link: link, source_message: source)
    link.chat_session.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Done." } ])

    2.times { Coworkers::MessageReply.after_chat_turn(chat_session: link.chat_session, user_message: incoming, turn_succeeded: true) }

    reply = source_chat.messages.where(role: "assistant").sole
    expect(reply.content).to include("text" => "Done.", "source" => "coworker_message")
    expect(reply.content.dig("coworker_message", "sender_id")).to eq(coworker.id)
    expect(source_chat.reload).not_to be_turn_in_flight
  end

  it "posts one source-chat failure message" do
    source = source_message("@maya-mentions help")
    2.times { described_class.fail!(source_message: source, coworker: coworker, error: RuntimeError.new("boom")) }

    failures = source_chat.messages.where(role: "system")
    expect(failures.one?).to be(true)
    expect(failures.first.extract_text_from_content).to include("could not finish")
  end
end
