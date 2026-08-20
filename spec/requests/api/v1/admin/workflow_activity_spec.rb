require "rails_helper"

RSpec.describe "API: /api/v1/admin/activity", type: :request do
  around do |example|
    Dir.mktmpdir("syrus-workflow-activity-spool") do |dir|
      previous = ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"]
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = dir
      Observability::EventSink.clear!(kind: :workflow_activity)
      example.run
      Observability::EventSink.clear!(kind: :workflow_activity)
    ensure
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = previous
    end
  end

  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

  around do |example|
    Observability::EventSink.clear!(kind: :workflow_activity)
    example.run
    Observability::EventSink.clear!(kind: :workflow_activity)
  end

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

    get "/api/v1/admin/activity", params: { job_id: job.id, event_type: "workflow_created" }, headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events")).to include(
      hash_including(
        "event_type" => "workflow_created",
        "job" => hash_including("id" => job.id)
      )
    )
  end
end
