require "rails_helper"

RSpec.describe Mcp::Tools::SpawnChatsTool do
  include ActiveJob::TestHelper

  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let!(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def call_tool(chats:, reason: nil)
    described_class.call(chats: chats, reason: reason, server_context: { chat_session: chat_session })
  end

  def body(response)
    JSON.parse(response.content.first.fetch(:text), symbolize_names: true)
  end

  it "creates one grouped pending action without creating chats" do
    expect {
      response = call_tool(chats: [ { prompt: "Find bugs", title: "Bug hunt" }, { prompt: "Review tests" } ], reason: "Parallel review")
      group = PendingActionGroup.find(body(response).fetch(:pending_action_group_id))

      expect(group).to have_attributes(reason: "Parallel review")
      expect(group.chat_pending_actions.count).to eq(2)
      expect(group.chat_pending_actions.pluck(:action).uniq).to eq([ "spawn_chat" ])
    }.not_to change(ChatSession, :count)
  end

  it "rejects invalid batches before creating pending actions" do
    inaccessible = Factories.repository(user: Factories.user, owner: "private", name: "repo")
    invalid_batches = [
      [ [], "must not be empty" ],
      [ Array.new(11) { { prompt: "work" } }, "more than 10" ],
      [ [ { prompt: " " } ], "prompt must not be blank" ],
      [ [ { prompt: "work", provider: "unknown" } ], "provider is unknown" ],
      [ [ { prompt: "work", repository: inaccessible.slug } ], "repository is not accessible" ]
    ]

    invalid_batches.each do |chats, message|
      response = call_tool(chats: chats)
      expect(response).to be_error
      expect(response.content.first.fetch(:text)).to include(message)
    end
    expect(PendingActionGroup.count).to eq(0)
  end

  it "confirms each chat with its provider, title, repository, and first message, then reports the ids" do
    second_repository = Factories.repository(user: user, owner: "acme", name: "api")
    user.update!(codex_api_key: "sk-test")
    provider = "codex"
    response = call_tool(chats: [
      { prompt: "Find bugs", title: "Bug hunt", provider: provider },
      { prompt: "Review API", repository: second_repository.slug }
    ])
    group = PendingActionGroup.find(body(response).fetch(:pending_action_group_id))

    expect { group.confirm_all!(user: user) }.to change(ChatSession, :count).by(2)

    spawned = ChatSession.order(:id).last(2)
    expect(spawned.map(&:repository)).to eq([ repository, second_repository ])
    expect(spawned.map(&:chat_provider)).to eq([ provider, user.effective_chat_provider ])
    expect(spawned.map(&:title)).to eq([ "Bug hunt", nil ])
    expect(spawned.map { |chat| chat.messages.first.content["text"] }).to eq([ "Find bugs", "Review API" ])

    notice = chat_session.messages.where(role: "system").order(:id).last.content.fetch("text")
    expect(notice).to include("CHAT-#{spawned.first.id} (#{spawned.first.chat_provider}): Bug hunt")
    expect(notice).to include("CHAT-#{spawned.second.id} (#{spawned.second.chat_provider}): Review API")
  end

  it "continues after one member fails and reports both outcomes" do
    response = call_tool(chats: [
      { prompt: "Will fail" },
      { prompt: "Will succeed" }
    ])
    group = PendingActionGroup.find(body(response).fetch(:pending_action_group_id))
    allow(ChatSessions::Creator).to receive(:new).and_wrap_original do |method, **args|
      raise "creation exploded" if args[:prompt] == "Will fail"

      method.call(**args)
    end

    expect { group.confirm_all!(user: user) }.to change(ChatSession, :count).by(1)

    notice = chat_session.messages.where(role: "system").order(:id).last.content.fetch("text")
    expect(notice).to include("Failed: Will fail — RuntimeError: creation exploded")
    expect(notice).to match(/CHAT-\d+ \(.+\): Will succeed/)
  end

  it "creates nothing when rejected" do
    group = PendingActionGroup.find(body(call_tool(chats: [ { prompt: "Do work" } ])).fetch(:pending_action_group_id))

    expect { group.reject_all! }.not_to change(ChatSession, :count)
  end

  it "enforces the batch limit again when pending-action payloads are built directly" do
    members = Array.new(11) do
      { action: "spawn_chat", payload: { "prompt" => "Work", "batch_size" => 1 } }
    end

    expect {
      PendingActionGroup.create_with_members!(chat_session: chat_session, member_attributes: members)
    }.to raise_error(ActiveRecord::RecordInvalid, /group cannot contain more than 10 chats/)

    expect(PendingActionGroup.count).to eq(0)
  end
end
