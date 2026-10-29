require "rails_helper"

RSpec.describe Coworkers::MessageDeliveryJob do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  def create_coworker(name:, handle:)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: name, handle: handle, workspace_repo: repository.remote_url)
    chat = ChatSession.create!(user: owner, repository: repository, title: name)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    [ coworker, chat ]
  end

  it "records outgoing and incoming chat blocks and starts an idle receiver turn" do
    sender, sender_chat = create_coworker(name: "Maya", handle: "maya")
    receiver, receiver_chat = create_coworker(name: "Rin", handle: "rin")

    expect { described_class.perform_now(sender.id, receiver.id, "Check the launch plan.", { "origin_turn_id" => 42, "hop_count" => 2 }) }
      .to have_enqueued_job(ChatTurnJob)

    expect(sender_chat.messages.last).to have_attributes(
      role: "system",
      content: include("text" => "Message to @rin\n\nCheck the launch plan.",
                       "coworker_message" => include("direction" => "outgoing", "receiver_handle" => "rin"))
    )
    expect(receiver_chat.messages.last).to have_attributes(
      role: "user",
      content: include("text" => "Message from @maya\n\nCheck the launch plan.",
                       "coworker_message" => include("direction" => "incoming", "sender_handle" => "maya", "origin_turn_id" => 42, "hop_count" => 2))
    )
    expect(receiver_chat.reload).to be_turn_in_flight
    expect(sender_chat.reload).not_to be_turn_in_flight
  end

  it "queues delivery behind a receiver turn already in flight" do
    sender, = create_coworker(name: "Maya", handle: "maya")
    receiver, receiver_chat = create_coworker(name: "Rin", handle: "rin")
    active = receiver_chat.messages.create!(role: "user", content: { "text" => "Working" }, skip_turn_trigger: true)
    receiver_chat.update_columns(current_turn_message_id: active.id, turn_in_flight: true)

    expect { described_class.perform_now(sender.id, receiver.id, "Wait your turn.", { "origin_turn_id" => active.id, "hop_count" => 1 }) }
      .not_to have_enqueued_job(ChatTurnJob)

    queued = receiver_chat.reload.queued_messages.last
    expect(queued.content).to include(
      "_role" => "user",
      "text" => "Message from @maya\n\nWait your turn.",
      "coworker_message" => include("direction" => "incoming")
    )
    expect(queued.content.dig("coworker_message", "hop_count")).to eq(1)
    expect(receiver_chat.messages.map(&:extract_text_from_content)).not_to include(a_string_including("Wait your turn"))
  end

  it "drops malformed delivery contexts without writing either chat" do
    sender, sender_chat = create_coworker(name: "Maya", handle: "maya")
    receiver, receiver_chat = create_coworker(name: "Rin", handle: "rin")

    expect {
      described_class.perform_now(sender.id, receiver.id, "Untraceable.", { "origin_turn_id" => nil, "hop_count" => 1 })
    }.not_to change { sender_chat.messages.count + receiver_chat.messages.count + receiver_chat.queued_messages.count }
  end


  it "preserves origin and hop metadata while waiting in the queue" do
    sender, = create_coworker(name: "Maya", handle: "maya")
    receiver, receiver_chat = create_coworker(name: "Rin", handle: "rin")
    active = receiver_chat.messages.create!(role: "user", content: { "text" => "Working" }, skip_turn_trigger: true)
    receiver_chat.update_columns(current_turn_message_id: active.id, turn_in_flight: true)

    described_class.perform_now(sender.id, receiver.id, "Queued metadata.", { "origin_turn_id" => 912, "hop_count" => 3 })
    queued = receiver_chat.reload.queued_messages.last
    receiver_chat.update!(current_turn_message_id: nil, turn_in_flight: false)
    ChatQueuedMessagePromoter.deliver_one_if_idle!(receiver_chat)

    expect(queued.reload.delivered_at).to be_present
    expect(receiver_chat.messages.last.content.fetch("coworker_message")).to include("origin_turn_id" => 912, "hop_count" => 3)
  end

  it "sets skip_turn_trigger explicitly on the sender-side block" do
    sender, sender_chat = create_coworker(name: "Maya", handle: "maya")
    receiver, receiver_chat = create_coworker(name: "Rin", handle: "rin")
    job = described_class.new
    allow(job).to receive(:main_chat) { |coworker| coworker.id == sender.id ? sender_chat : receiver_chat }
    expect(sender_chat.messages).to receive(:create!)
      .with(hash_including(role: "system", skip_turn_trigger: true))
      .and_call_original

    job.perform(sender.id, receiver.id, "Explicitly non-triggering.", { "origin_turn_id" => 42, "hop_count" => 1 })
  end
end
