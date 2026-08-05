require "rails_helper"

RSpec.describe "API: /api/v1/app speech-to-text", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:chat) { ChatSession.create!(user: user) }

  def parse_body
    JSON.parse(response.body)
  end

  it "returns 404 for batch and stream endpoints when the feature is disabled" do
    sign_in_as(user)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text"
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_disabled")

    post "/api/v1/app/chats/#{chat.id}/speech_to_text/stream"
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_disabled")
  end

  it "returns a deterministic backend-unavailable response when backend STT is not configured" do
    sign_in_as(user)
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_backend_unavailable")
  end
end
