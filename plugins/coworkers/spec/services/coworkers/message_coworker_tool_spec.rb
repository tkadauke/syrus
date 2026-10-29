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
    Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin", workspace_repo: repository.remote_url)
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
  end

  it "refuses a pair after its delivery rate limit is reached" do
    receiver = Coworkers::Coworker.create!(owner_user: owner, name: "Rin", handle: "rin", workspace_repo: repository.remote_url)
    refusal = Coworkers::MessageRateLimiter::Result.new(allowed: false, retry_after_seconds: 37)
    expect(Coworkers::MessageRateLimiter).to receive(:reserve).with(sender: sender, receiver: receiver).and_return(refusal)

    response = nil
    expect { response = call("rin") }.not_to have_enqueued_job(Coworkers::MessageDeliveryJob)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("rate limit reached for @maya and @rin", "try again in 37 seconds")
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
end
