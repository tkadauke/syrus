require "rails_helper"

RSpec.describe "coworker environment chat events" do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Notifier", handle: "environment-notifier",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:chat) { ChatSession.create!(user: owner, title: "Notifier") }

  before { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }

  it "delivers a safe structured lifecycle event to the main chat" do
    event = Syrus::DomainEvent.new(name: "coworker_environment.candidate", payload: {
      "coworker_id" => coworker.id, "environment_id" => 12, "revision_id" => 34,
      "inspection" => { "v" => 1, "state" => "candidate" }
    })

    Coworkers::Subscribers.deliver_environment_event(event)

    message = chat.messages.last
    expect(message).to have_attributes(role: "system")
    expect(message.content.fetch("coworker_environment_event")).to include(
      "type" => "candidate", "environment_id" => 12,
      "inspection" => { "v" => 1, "state" => "candidate" }
    )
  end

  it "ignores lifecycle events when the coworker has no main chat" do
    coworker.coworker_chats.destroy_all
    event = Syrus::DomainEvent.new(name: "coworker_environment.revoked", payload: {
      "coworker_id" => coworker.id, "environment_id" => 12, "revision_id" => 34
    })

    expect { Coworkers::Subscribers.deliver_environment_event(event) }
      .not_to change(ChatMessage, :count)
  end
end
