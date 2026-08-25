require "rails_helper"

RSpec.describe "API: /api/v1/admin/backend_exceptions", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

  it "requires an API token" do
    get "/api/v1/admin/backend_exceptions"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns backend exceptions to admin API clients" do
    job = Factories.job(user: admin)
    BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "action_controller",
      exception_class: "NoMethodError",
      message: "undefined method map for nil",
      path: "/jobs/3188",
      request_id: "req-123",
      job: job
    )

    get "/api/v1/admin/backend_exceptions", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("events", 0)).to include(
      "exception_class" => "NoMethodError",
      "message" => "undefined method map for nil",
      "path" => "/jobs/3188",
      "request_id" => "req-123",
      "job_slug" => job.slug
    )
    expect(response.parsed_body.dig("events", 0, "actions")).to include(
      include("id" => "file_job", "label" => "File Job", "event_type" => "backend_exception")
    )
  end

  it "sorts backend exceptions by supported columns" do
    BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "active_job",
      exception_class: "RuntimeError",
      message: "zulu failure",
      job_class: "ZJob"
    )
    BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "action_controller",
      exception_class: "NoMethodError",
      message: "alpha failure",
      path: "/alpha"
    )

    get "/api/v1/admin/backend_exceptions", params: { sort: "error", direction: "asc", revision_scope: "all" }, headers: auth

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("filters", "sort")).to eq("error")
    expect(body.dig("filters", "direction")).to eq("asc")
    expect(body.fetch("events").map { |event| event.fetch("message") }).to eq([ "alpha failure", "zulu failure" ])
  end
end
