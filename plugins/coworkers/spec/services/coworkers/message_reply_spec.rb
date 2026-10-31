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

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true) }
      .to have_enqueued_job(Coworkers::MessageDeliveryJob)
      .with(replier.id, original_sender.id, "Final answer", { "origin_turn_id" => 42, "hop_count" => 2 })
  end

  it "does not deliver or show the no-reply sentinel" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    reply = replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "  NO_REPLY\n" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(ChatMessage.exists?(reply.id)).to be(false)
  end

  it "does not deliver or show an empty assistant reply" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    reply = replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => " \n" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(ChatMessage.exists?(reply.id)).to be(false)
  end

  it "ignores empty replies and turns not triggered by an incoming coworker message" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    ordinary = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, source: "owner")
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Not forwarded" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: ordinary, turn_succeeded: true) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
  end

  it "records a refusal and stops the chain at the hop cap" do
    original_sender, original_chat = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, hop_count: 3)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "One hop too far" } ])

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true) }
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

    expect { described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true) }
      .not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
    expect(replier_chat.messages.last.content.dig("coworker_message", "status")).to eq("refused")

    original_sender.update!(state: "active")
    allow(Coworkers::MessageRateLimiter).to receive(:reserve)
      .and_return(Coworkers::MessageRateLimiter::Result.new(allowed: false, retry_after_seconds: 12))
    second_incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Another answer" } ])
    described_class.after_chat_turn(chat_session: replier_chat, user_message: second_incoming, turn_succeeded: true)
    expect(replier_chat.messages.last.content.dig("coworker_message", "status")).to eq("rate_limited")
  end

  it "orients the reply toward the sender and explains automatic delivery and stopping" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier, hop_count: 1)

    orientation = described_class.chat_turn_orientation(chat_session: replier_chat, message: incoming, user_note: "Can you check?")

    expect(orientation).to include("@maya", "delivered to them automatically", "2 exchanges remain", "NO_REPLY")
  end

  it "does not forward partial replies from failed or cancelled turns" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Partial answer" } ])

    expect {
      described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: false)
      described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming)
    }.not_to have_enqueued_job(Coworkers::MessageDeliveryJob)
  end

  it "claims an automatic reply once across turn retries" do
    original_sender, = create_coworker(name: "Maya", handle: "maya")
    replier, replier_chat = create_coworker(name: "Rin", handle: "rin")
    incoming = incoming_message(chat: replier_chat, sender: original_sender, receiver: replier)
    replier_chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Only once" } ])

    2.times do
      described_class.after_chat_turn(chat_session: replier_chat, user_message: incoming, turn_succeeded: true)
    end

    deliveries = enqueued_jobs.select { |job| job.fetch(:job) == Coworkers::MessageDeliveryJob }
    expect(deliveries.one?).to be(true)
    expect(incoming.reload.content.dig("coworker_message", "auto_reply_claimed")).to be(true)
  end

  it "runs a queued two-coworker exchange through three hops and then stops" do
    maya, maya_chat = create_coworker(name: "Maya", handle: "maya")
    rin, rin_chat = create_coworker(name: "Rin", handle: "rin")

    Coworkers::MessageDeliveryJob.perform_now(maya.id, rin.id, "Start", { "origin_turn_id" => 42, "hop_count" => 1 })
    clear_enqueued_jobs

    [ [ rin, rin_chat ], [ maya, maya_chat ], [ rin, rin_chat ] ].each_with_index do |(_coworker, chat), index|
      incoming = chat.messages.where(role: "user").order(:id).last
      chat.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Reply #{index + 1}" } ])
      described_class.after_chat_turn(chat_session: chat, user_message: incoming, turn_succeeded: true)
      chat.end_turn_for!(incoming)

      if index < 2
        perform_enqueued_jobs(only: Coworkers::MessageDeliveryJob)
        clear_enqueued_jobs
      end
    end

    incoming_hops = [ maya_chat, rin_chat ].flat_map do |chat|
      chat.messages.where(role: "user").filter_map { |message| message.content.dig("coworker_message", "hop_count") }
    end.sort
    expect(incoming_hops).to eq([ 1, 2, 3 ])
    expect(enqueued_jobs).not_to include(hash_including(job: Coworkers::MessageDeliveryJob))
    expect(rin_chat.messages.order(:id).last.content.fetch("text")).to include("reached its 3-hop limit")
  end
end
