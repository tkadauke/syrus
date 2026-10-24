require "rails_helper"

RSpec.describe "API: /api/v1/app/ui_engagement_samples", type: :request do
  let(:user) { Factories.user }
  let(:payload) do
    {
      ui_engagement_sample: {
        route_id: "chat.show", route_params: { chat_id: "17" },
        started_at: 2.minutes.ago.iso8601, ended_at: Time.current.iso8601,
        active_ms: 30_000, visible_ms: 60_000
      }
    }
  end

  it "requires authentication" do
    post "/api/v1/app/ui_engagement_samples", params: payload
    expect(response).to have_http_status(:unauthorized)
  end

  it "discards samples while collection is disabled" do
    sign_in_as(user)

    expect { post "/api/v1/app/ui_engagement_samples", params: payload }.not_to change(UiEngagementSample, :count)
    expect(response).to have_http_status(:no_content)
  end

  it "records valid samples for only the signed-in user when enabled" do
    AppSetting.current.update!(ui_engagement_telemetry_enabled: true)
    sign_in_as(user)

    expect { post "/api/v1/app/ui_engagement_samples", params: payload }.to change(user.ui_engagement_samples, :count).by(1)
    expect(response).to have_http_status(:accepted)
    expect(user.ui_engagement_samples.last.route_params).to eq("chat_id" => "17")
  end

  it "rejects absurd durations and unexpected route parameters" do
    AppSetting.current.update!(ui_engagement_telemetry_enabled: true)
    sign_in_as(user)
    payload[:ui_engagement_sample][:active_ms] = 25.hours.in_milliseconds
    payload[:ui_engagement_sample][:route_params] = { repository_id: "2" }

    post "/api/v1/app/ui_engagement_samples", params: payload

    expect(response).to have_http_status(:unprocessable_content)
    expect(UiEngagementSample).not_to exist
  end
end
