require "rails_helper"

RSpec.describe "API: /api/v1/app/chats/:id/scheduled_messages", type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Planning") }

  def parse_body
    JSON.parse(response.body)
  end

  before do
    clear_enqueued_jobs
  end

  it "creates a scheduled chat message for the current user's chat" do
    sign_in_as(user)
    fire_at = 2.hours.from_now

    expect {
      post "/api/v1/app/chats/#{chat_session.id}/scheduled_messages", params: {
        scheduled_message: {
          body: "Check JOB-1234.",
          fire_at: fire_at.iso8601
        }
      }
    }.to change(ScheduledChatMessage, :count).by(1)

    expect(response).to have_http_status(:created)
    scheduled_message = ScheduledChatMessage.last
    expect(scheduled_message).to have_attributes(
      chat_session: chat_session,
      user: user,
      body: "Check JOB-1234."
    )
    expect(scheduled_message.fire_at.to_i).to eq(fire_at.to_i)
    expect(ScheduledChatMessageFireJob).to have_been_enqueued.with(scheduled_message.id)
    expect(parse_body).to include("id" => scheduled_message.id, "message" => "Message scheduled.")
  end

  it "rejects blank bodies and past fire times" do
    sign_in_as(user)

    post "/api/v1/app/chats/#{chat_session.id}/scheduled_messages", params: {
      scheduled_message: { body: "", fire_at: 1.hour.from_now.iso8601 }
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Message cannot be blank.")

    post "/api/v1/app/chats/#{chat_session.id}/scheduled_messages", params: {
      scheduled_message: { body: "Too late", fire_at: 1.minute.ago.iso8601 }
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("fire_at must be in the future.")
  end

  it "does not allow scheduling into another user's chat" do
    sign_in_as(other_user)

    post "/api/v1/app/chats/#{chat_session.id}/scheduled_messages", params: {
      scheduled_message: { body: "Hijack", fire_at: 1.hour.from_now.iso8601 }
    }

    expect(response).to have_http_status(:not_found)
    expect(ScheduledChatMessage.count).to eq(0)
  end
end
