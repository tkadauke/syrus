require "rails_helper"

RSpec.describe "API: /api/v1/admin/activity", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

  it "requires an API token" do
    get "/api/v1/admin/activity"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns workflow activity to admin API clients" do
    job = Factories.job_record(user: admin, state: "queued")
    WorkflowActivityEvent.delete_all
    WorkflowActivity.synchronously do
      WorkflowActivity.record!(
        event_type: "workflow_created",
        source: "spec",
        job: job,
        message: "Workflow created."
      )
    end

    get "/api/v1/admin/activity", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("events", 0, "event_type")).to eq("workflow_created")
  end
end
