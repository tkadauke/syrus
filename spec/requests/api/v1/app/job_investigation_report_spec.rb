require "rails_helper"

RSpec.describe "App API investigation report", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job(
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow?",
      issue_body: "Investigate: why does /dashboard feel slow?",
      investigation: true
    )
  end

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  it "returns investigation:true and a nil report before submit_report runs" do
    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("job", "investigation")).to eq(true)
    expect(body["report"]).to be_nil
  end

  it "exposes the submitted report, including resolved artifact references, in the job detail payload" do
    run = job.workflows.last.first_step.runs.first
    run.workflow.set_typed_artifact!(
      type: "dashboard_screenshot",
      title: "Dashboard screenshot",
      payload: { "image_url" => "https://example.com/shot.png" },
      renderer_type: :image_diff
    )

    Mcp::Tools::SubmitReportTool.call(
      title: "Dashboard slowness",
      narrative: "It's slow because of an N+1 query.",
      findings: [ "N+1 query in DashboardController#index" ],
      references: [ { "type" => "dashboard_screenshot", "caption" => "The offending screen" } ],
      server_context: { run: run }
    )

    get "/api/v1/app/jobs/#{job.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body

    expect(body["report"]).to include(
      "workflow_id" => run.workflow_id,
      "title" => "Dashboard slowness",
      "narrative" => "It's slow because of an N+1 query.",
      "findings" => [ "N+1 query in DashboardController#index" ]
    )
    expect(body["report"]["references"]).to contain_exactly(
      include(
        "type" => "dashboard_screenshot",
        "caption" => "The offending screen",
        "artifact" => include("type" => "dashboard_screenshot", "title" => "Dashboard screenshot", "renderer_type" => "image_diff")
      )
    )
  end

  it "does not expose a report for a regular (non-investigation) job detail payload" do
    non_investigation_job = Factories.job(repository: repo, issue_number: 42)

    get "/api/v1/app/jobs/#{non_investigation_job.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("job", "investigation")).to eq(false)
    expect(body["report"]).to be_nil
  end
end
