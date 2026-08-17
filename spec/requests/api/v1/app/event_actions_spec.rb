require "rails_helper"

RSpec.describe "API: /api/v1/app/event_actions", type: :request do
  let!(:admin_seed) { Factories.user(admin: true) }
  let(:user) { Factories.user(admin: false) }

  before do
    AppSetting.current.update!(report_issue_repo_slug: "operator/syrus")
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "files a browser error job with the complete captured event payload" do
    repository = Factories.repository(user: user, owner: "operator", name: "syrus")
    event = BrowserErrorEvent.record!(
      user: user,
      payload: {
        "fingerprint" => "map-fingerprint",
        "name" => "TypeError",
        "message" => "undefined is not an object (evaluating 'n.map')",
        "stack" => "at JobDetails.tsx:42",
        "component_stack" => "JobDetails",
        "path" => "/jobs/3188",
        "route_id" => "job",
        "route_params" => { "id" => "3188" },
        "recent_api_requests" => [ { "path" => "/api/v1/app/jobs/3188", "status" => 200 } ],
        "recent_errors" => [ { "message" => "prior failure" } ],
        "metadata" => { "boundary" => "route" }
      }
    )
    sign_in_as(user)

    expect {
      post "/api/v1/app/event_actions/file_job", params: { event_type: "browser_error", event_id: event.id }
    }.to change(Job, :count).by(1)

    expect(response).to have_http_status(:created)
    job = Job.last
    expect(parse_body).to include("message" => "Job filed.", "job_id" => job.id)
    expect(job.repository).to eq(repository)
    expect(job.issue_title).to include("Fix browser error: undefined is not an object")
    expect(job.issue_body).to include(
      "Full browser error payload:",
      "\"route_params\":",
      "\"id\": \"3188\"",
      "\"recent_api_requests\":",
      "\"recent_errors\":",
      "\"metadata\":"
    )
  end

  it "prevents users from filing jobs for another user's browser error" do
    owner = Factories.user
    event = BrowserErrorEvent.record!(user: owner, payload: { "fingerprint" => "other", "message" => "boom" })
    sign_in_as(user)

    post "/api/v1/app/event_actions/file_job", params: { event_type: "browser_error", event_id: event.id }

    expect(response).to have_http_status(:forbidden)
  end

  it "allows admins to file backend exception jobs" do
    Factories.repository(user: admin_seed, owner: "operator", name: "syrus")
    event = BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "action_controller",
      exception_class: "NoMethodError",
      message: "undefined method map for nil",
      path: "/jobs/3188",
      request_id: "req-123",
      metadata: { "duration_ms" => 1234.5 }
    )
    sign_in_as(admin_seed)

    expect {
      post "/api/v1/app/event_actions/file_job", params: { event_type: "backend_exception", event_id: event.id }
    }.to change(Job, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(Job.last.issue_body).to include(
      "Full backend exception payload:",
      "\"request_id\": \"req-123\"",
      "\"duration_ms\": \"1234.5\""
    )
  end

  it "requires admin access for backend exception jobs" do
    event = BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "active_job",
      exception_class: "RuntimeError",
      message: "boom"
    )
    sign_in_as(user)

    post "/api/v1/app/event_actions/file_job", params: { event_type: "backend_exception", event_id: event.id }

    expect(response).to have_http_status(:forbidden)
  end
end
