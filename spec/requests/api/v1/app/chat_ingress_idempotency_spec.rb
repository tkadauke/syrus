require "rails_helper"

RSpec.describe "Chat ingress idempotency", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }

  let(:chat) { ChatSession.create!(user: user) }

  before { sign_in_as(user) }

  it "replays a successful message send without repeating its effects" do
    params = { client_idempotency_key: SecureRandom.uuid, chat_message: { text: "Only once" } }

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: params
    }.to change(ChatMessage, :count).by(1)
      .and change(ChatIngressReceipt, :count).by(1)
      .and have_enqueued_job(ChatTurnJob).once
    first_body = response.parsed_body

    expect {
      post "/api/v1/app/chats/#{chat.id}/message", params: params
    }.not_to change(ChatMessage, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(first_body)
    expect(ChatTurnJob).to have_been_enqueued.once
  end

  it "rejects changed text or attachment identity for the same key" do
    key = SecureRandom.uuid
    post "/api/v1/app/chats/#{chat.id}/message", params: {
      client_idempotency_key: key,
      chat_message: { text: "Original", attachments: [ { name: "one.txt", mime_type: "text/plain", data: "MQ==" } ] }
    }

    post "/api/v1/app/chats/#{chat.id}/message", params: {
      client_idempotency_key: key,
      chat_message: { text: "Original", attachments: [ { name: "two.txt", mime_type: "text/plain", data: "MQ==" } ] }
    }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("idempotency_conflict")
    expect(chat.messages.where(role: "user").count).to eq(1)
  end

  it "returns the original chat when initial creation is retried" do
    key = SecureRandom.uuid
    params = { client_idempotency_key: key, chat_message: { text: "Start once" } }

    expect { post "/api/v1/app/chats", params: params }.to change(ChatSession, :count).by(1)
    original_id = response.parsed_body.dig("chat", "id")

    expect { post "/api/v1/app/chats", params: params }.not_to change(ChatSession, :count)
    expect(response.parsed_body.dig("chat", "id")).to eq(original_id)
  end

  it "carries a queued send key onto its later promoted message" do
    chat.update!(turn_in_flight: true)
    key = SecureRandom.uuid

    post "/api/v1/app/chats/#{chat.id}/queued_messages", params: { client_idempotency_key: key, chat_message: { text: "After this turn" } }

    expect(response).to have_http_status(:ok)
    queued = chat.chat_queued_messages.find_by!(client_idempotency_key: key)
    chat.update!(turn_in_flight: false)
    expect(ChatQueuedMessagePromoter.deliver_one_if_idle!(chat)).to be(true)
    expect(chat.messages.find_by!(client_idempotency_key: key).content.fetch("text")).to eq("After this turn")
    expect(queued.reload.delivered_at).to be_present
  end
end
