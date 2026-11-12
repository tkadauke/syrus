require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/backend_exceptions", type: :request do
  it "keeps list rows slim and serves controls and detail separately" do
    admin = Factories.user(admin: true)
    event = BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "action_controller",
      exception_class: "NoMethodError",
      message: "undefined method map for nil",
      backtrace: "app/models/job.rb:12",
      path: "/jobs/3188",
      hostname: "worker-a"
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/backend_exceptions", params: { revision_scope: "all" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("events", 0)).not_to have_key("backtrace")
    expect(response.parsed_body).not_to have_key("filter_schema")
    expect(response.parsed_body.fetch("actions")).to include(include("id" => "file_job"))

    get "/api/v1/app/admin/backend_exceptions/#{event.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("backtrace" => "app/models/job.rb:12", "hostname" => "worker-a")

    get "/api/v1/app/admin/backend_exceptions/controls"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("filter_schema")).to be_present
    expect(response.parsed_body.fetch("sources")).to include("action_controller")
  end
end
