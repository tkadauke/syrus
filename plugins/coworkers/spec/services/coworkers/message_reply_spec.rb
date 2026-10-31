require "rails_helper"

RSpec.describe Coworkers::MessageReply do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  def create_coworker(name:, handle:, state: "active")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: name, handle: handle, state: state, workspace_repo: repository.remote_url)
    chat = ChatSession.create!(user: owner, repository: repository, title: name)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    [ coworker, chat ]
  end

  def incoming_message(chat:, sender:, receiver:, hop_count: 1, source: "coworker_message", direction: "incoming")
    chat.messages.create!(
      role: "user",
      content: {
        "text" => "Message from @#{sender.handle}\n\nCan you check?",
        "source" => source,
        "coworker_message" => {
          "direction" => direction,
          "sender_id" => sender.id,
          "sender_handle" => sender.handle,
          "receiver_id" => receiver.id,
          "receiver_handle" => receiver.handle,
          "origin_turn_id" => 42,
          "hop_count" => hop_count
        }
      },
      skip_turn_trigger: true
    )
  end

  before do
    allow(Coworkers::MessageRateLimiter).to receive(:reserve)
      .and_return(Coworkers::MessageRateLimiter::Result.new(allowed: true, retry_after_seconds: 0))
  end

  it "delivers the final assistant reply to the sender with the next hop" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, hop_count: 1)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "First draft" } ])
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Final answer" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming) }
      .to have_enqueued_job(Coworkers::MessageDeliveryJob)
      .with(replier.id, original_sender.id, "Final answer", { "origin_turn_id" => 42, "hop_count" => 2 })
  end

  it "does not deliver or show the no-reply sentinel" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    reply = replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "  NO_REPLY\n" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(ChatMessage.exists?(reply.id)).to be(false)
  end

  it "does not deliver or show an empty assistant reply" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    reply = replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => " \n" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(ChatMessage.exists?(reply.id)).to be(false)
  end

  it "ignores empty replies and turns not triggered by an incoming coworker message" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    ordinary = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, source: "owner")
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Not forwarded" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: ordinary) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
  end

  it "records a refusal and stops the chain at the hop cap" do
    original_sender, original_chat = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, hop_count: 3)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "One hop too far" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(replier_chat.messages.last.content).to include(
      "text" => include("reached its 3-hop limit"),
      "coworker_message" => include("status" => "refused", "hop_count" => 4)
    )
    expect(original_chat.messages.count).to eq(0)
  end

  it "records refusals for inactive recipients and rate limits" do
    original_sender, = create_coworker(name: "Maya", handle: "maya", state: "paused")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Answer" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(replier_chat.messages.last.content.dig("coworker_message", "status")).to eq("refused")

    original_sender.update!(state: "active")
    allow(Coworkers::MessageRateLimiter).to receive(:reserve)
      .and_return(Coworkers::MessageRateLimiter::Result.new(allowed: false, retry_after_seconds: 12))
    described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming)
    expect(replier_chat.messages.last.content.dig("coworker_message", "status")).to eq("rate_limited")
  end

  it "orients the reply toward the sender and explains automatic delivery and stopping" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, hop_count: 1)

    orientation = described_class.chat_turn_orientation(chat_session: replier_chat, message: incoming, user_note: "Can you check?")

    expect(orientation).to include("@maya", "delivered to them automatically", "2 exchanges remain", "NO_REPLY")
  end
end
