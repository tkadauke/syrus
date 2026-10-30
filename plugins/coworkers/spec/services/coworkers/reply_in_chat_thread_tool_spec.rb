require "rails_helper"

RSpec.describe Coworkers::ReplyInChatThreadTool do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-reply",
      workspace_repo: repository.remote_url
    )
  end
  let(:coworker_chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:owner_chat) { ChatSession.create!(user: owner, title: "Owner chat") }

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")
    clear_enqueued_jobs
  end

  def call(**arguments)
    described_class.call(**arguments, server_context: { chat_session: coworker_chat })
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  def thread(**attributes)
    ChatBridgeThread.create!(
      origin_chat_session: owner_chat,
      target_chat_session: coworker_chat,
      opened_by_user: owner,
      max_hops: 3,
      **attributes
    )
  end

  it "replies on an owner-opened thread and decrements the remaining hops" do
    bridge = thread

    response = call(thread_id: bridge.id, text: "The answer")

    expect(response).not_to be_error
    expect(payload(response)).to include(
      thread_id: bridge.id, hop_count: 1, max_hops: 3, hops_remaining: 2,
      target_chat_session_id: owner_chat.id
    )
    expect(ChatWakeup.sole).to have_attributes(chat_session: owner_chat, prompt: "The answer")
  end

  it "refuses a thread the coworker's chat is not in" do
    other_chat = ChatSession.create!(user: owner)
    bridge = ChatBridgeThread.create!(
      origin_chat_session: owner_chat, target_chat_session: other_chat, opened_by_user: owner
    )

    expect(call(thread_id: bridge.id, text: "Nope")).to be_error
    expect(ChatWakeup.count).to eq(0)
  end

  it "refuses a thread not opened by the coworker's owner" do
    other_user = Factories.user
    bridge = thread(opened_by_user: other_user)

    expect(call(thread_id: bridge.id, text: "Nope")).to be_error
    expect(ChatWakeup.count).to eq(0)
  end

  it "refuses an owner-opened thread whose counterpart belongs to another coworker" do
    other_coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Rin", handle: "rin-reply",
      workspace_repo: repository.remote_url
    )
    other_coworker_chat = ChatSession.create!(user: owner, repository: repository, title: "Rin")
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_coworker_chat, role: "main")
    bridge = ChatBridgeThread.create!(
      origin_chat_session: coworker_chat,
      target_chat_session: other_coworker_chat,
      opened_by_user: owner
    )

    response = call(thread_id: bridge.id, text: "Not through this tool")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not found or not accessible")
    expect(ChatWakeup.count).to eq(0)
  end

  it "refuses a closed thread" do
    bridge = thread(state: "closed")

    response = call(thread_id: bridge.id, text: "Too late")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("closed")
  end

  it "refuses a thread that has already reached its hop cap" do
    bridge = thread(hop_count: 3)

    response = call(thread_id: bridge.id, text: "One too many")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("hop limit")
    expect(ChatWakeup.count).to eq(0)
  end

  it "has no input for opening a new thread" do
    schema = described_class.input_schema_value.to_h.deep_symbolize_keys

    expect(schema.dig(:properties)).to include(:thread_id, :text)
    expect(schema.dig(:properties)).not_to include(:target_chat_session_id, :max_hops)
    expect { call(text: "Open", target_chat_session_id: owner_chat.id) }.to raise_error(ArgumentError)
    expect(ChatBridgeThread.count).to eq(0)
  end
end
