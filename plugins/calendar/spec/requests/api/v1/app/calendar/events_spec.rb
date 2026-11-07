require "rails_helper"

RSpec.describe "Calendar events API", type: :request do
  let(:user) { Factories.user }

  before do
    sign_in_as(user)
    allow(Calendar).to receive(:enabled?).and_return(true)
  end

  it "requires both range bounds" do
    get "/api/v1/app/calendar/events", params: { starts_at: Time.current.iso8601 }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns normalized events" do
    payload = { events: [], failures: [] }
    allow(Calendar::EventQuery).to receive(:call).and_return(payload)
    get "/api/v1/app/calendar/events", params: { starts_at: Time.current.iso8601, ends_at: 1.day.from_now.iso8601 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("events" => [], "failures" => [])
  end

  it "is unavailable while the plugin is disabled" do
    allow(Calendar).to receive(:enabled?).and_return(false)
    get "/api/v1/app/calendar/events", params: { starts_at: Time.current.iso8601, ends_at: 1.day.from_now.iso8601 }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects malformed timestamps without invoking providers" do
    expect(Calendar::EventQuery).not_to receive(:call)
    get "/api/v1/app/calendar/events", params: { starts_at: "next Tuesday", ends_at: 1.day.from_now.iso8601 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_calendar_range")
  end
end
