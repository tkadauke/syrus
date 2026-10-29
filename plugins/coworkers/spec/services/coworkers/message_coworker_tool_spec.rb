require "rails_helper"

RSpec.describe Coworkers::MessageCoworkerTool do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:sender) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }

  before { Coworkers::Chat.create!(coworker: sender, chat_session: chat, role: "main") }

  def call(handle)
    described_class.call(server_context: { chat_session: chat }, handle: handle, text: "Hello")
  end

  it "queues a delivery to an active coworker owned by the same user" do
    receiver = Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin", workspace_repo: repository.remote_url)

    expect { call("@rin") }.to have_enqueued_job(Coworkers::MessageDeliveryJob).with(sender.id, receiver.id, "Hello", { "origin_turn_id" => nil, "hop_count" => 1 })
  end

  it "refuses a coworker message chain beyond the hop limit" do
    receiver = Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin", workspace_repo: repository.remote_url)
    current_message = chat.messages.create!(
      role: "user",
      content: { "text" => "Message from @rin", "coworker_message" => { "origin_turn_id" => 42, "hop_count" => 3 } },
      skip_turn_trigger: true
    )

    response = nil
    expect {
      response = described_class.call(server_context: { chat_session: chat, current_message: current_message }, handle: "rin", text: "Hello")
    }.not_to have_enqueued_job(Coworkers::MessageDeliveryJob)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("3-hop limit")
    refusal = chat.messages.last
    expect(refusal).to have_attributes(role: "system")
    expect(refusal.content).to include(
      "text" => include("Message to @rin was not delivered"),
      "coworker_message" => include("status" => "refused", "receiver_id" => receiver.id, "origin_turn_id" => 42, "hop_count" => 4)
    )
  end

  it "refuses a pair after its delivery rate limit is reached" do
    receiver = Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin", workspace_repo: repository.remote_url)
    refusal = Coworkers::MessageRateLimiter::Result.new(allowed: false, retry_after_seconds: 37)
    expect(Coworkers::MessageRateLimiter).to receive(:reserve).with(sender: sender, receiver: receiver).and_return(refusal)

    response = nil
    expect { response = call("rin") }.not_to have_enqueued_job(Coworkers::MessageDeliveryJob)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("rate limit reached for @maya and @rin", "try again in 37 seconds")
    expect(chat.messages.last.content.fetch("coworker_message")).to include(
      "status" => "rate_limited", "receiver_id" => receiver.id, "hop_count" => 1
    )
  end

  it "stops a two-party ping-pong after three delivered hops" do
    rin, rin_chat = create_coworker_with_main_chat(name: "Rin", handle: "rin")
    allow(Coworkers::MessageRateLimiter).to receive(:reserve).and_return(allowed_rate_limit)

    expect(deliver(from_chat: chat, to: rin)).not_to be_error
    first = rin_chat.messages.last
    expect(deliver(from_chat: rin_chat, to: sender, current_message: first)).not_to be_error
    second = chat.messages.last

    rin_chat.update!(turn_in_flight: false, current_turn_message_id: nil)
    expect(deliver(from_chat: chat, to: rin, current_message: second)).not_to be_error
    ChatQueuedMessagePromoter.deliver_one_if_idle!(rin_chat)
    third = rin_chat.messages.last
    response = deliver(from_chat: rin_chat, to: sender, current_message: third)

    expect([ first, second, third ].map { |message| message.content.dig("coworker_message", "hop_count") }).to eq([ 1, 2, 3 ])
    expect(response).to be_error
    expect(response.content.first[:text]).to include("3-hop limit")
  end

  it "stops a three-party cycle after three delivered hops" do
    rin, rin_chat = create_coworker_with_main_chat(name: "Rin", handle: "rin")
    sol, sol_chat = create_coworker_with_main_chat(name: "Sol", handle: "sol")
    allow(Coworkers::MessageRateLimiter).to receive(:reserve).and_return(allowed_rate_limit)

    deliver(from_chat: chat, to: rin)
    first = rin_chat.messages.last
    deliver(from_chat: rin_chat, to: sol, current_message: first)
    second = sol_chat.messages.last
    deliver(from_chat: sol_chat, to: sender, current_message: second)
    third = chat.messages.last
    response = deliver(from_chat: chat, to: rin, current_message: third)

    expect([ first, second, third ].map { |message| message.content.dig("coworker_message", "hop_count") }).to eq([ 1, 2, 3 ])
    expect(response).to be_error
  end

  it "refuses Syrus, self, unknown, foreign, paused, and archived targets with clear results" do
    other_owner = Factories.user(email_address: "other-coworker@example.com")
    Coworkers::Coworker.create!(owner_user: other_owner, name: "Foreign", handle: "foreign", workspace_repo: repository.remote_url)
    %w[paused archived].each do |state|
      Coworkers::Coworker.create!(owner_user: owner, name: state.capitalize, handle: state, state: state, workspace_repo: repository.remote_url)
    end

    {
      "syrus" => "Syrus cannot receive",
      "maya" => "cannot message itself",
      "missing" => "not one of this owner's coworkers",
      "foreign" => "not one of this owner's coworkers",
      "paused" => "is paused",
      "archived" => "is archived"
    }.each do |handle, message|
      response = call(handle)
      expect(response).to be_error
      expect(response.content.first[:text]).to include(message)
    end
  end

  def create_coworker_with_main_chat(name:, handle:)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: name, handle: handle, workspace_repo: repository.remote_url)
    main_chat = ChatSession.create!(user: owner, repository: repository, title: name)
    Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")
    [ coworker, main_chat ]
  end

  def deliver(from_chat:, to:, current_message: nil)
    response = described_class.call(
      server_context: { chat_session: from_chat, current_message: current_message },
      handle: to.handle, text: "Continue"
    )
    return response if response.error?

    ActiveJob::Base.queue_adapter.enqueued_jobs.pop
    from = Coworkers::Chat.find_by!(chat_session: from_chat).coworker
    incoming = current_message&.content.to_h.fetch("coworker_message", {})
    context = {
      "origin_turn_id" => incoming["origin_turn_id"] || current_message&.id,
      "hop_count" => incoming.fetch("hop_count", 0).to_i + 1
    }
    Coworkers::MessageDeliveryJob.perform_now(from.id, to.id, "Continue", context)
    response
  end

  def allowed_rate_limit
    Coworkers::MessageRateLimiter::Result.new(allowed: true, retry_after_seconds: 0)
  end
end
