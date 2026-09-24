require "rails_helper"

RSpec.describe "investigation report in job detail payload" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    App::JobDetailPayload.build(job: job, user: user)
  end

  def investigation_job
    Factories.job(
      repository: repo,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow?",
      issue_body: "Investigate: why does /dashboard feel slow?",
      investigation: true
    )
  end

  def investigation_workflow_for(job)
    job.workflows.where(trigger_kind: "investigation").reorder(created_at: :desc, id: :desc).first!
  end

  it "marks the job as an investigation job and has no report before submit_report runs" do
    job = investigation_job

    payload = payload_for(job)

    expect(payload.dig(:job, :investigation)).to eq(true)
    expect(payload[:report]).to be_nil
  end

  it "exposes the submitted report, resolving references against typed_artifacts" do
    job = investigation_job
    workflow = investigation_workflow_for(job)
    submit_report_step = workflow.steps.find_by!(kind: "submit_report")
    run = submit_report_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    run.workflow.set_typed_artifact!(type: "dashboard_screenshot", title: "Dashboard screenshot", payload: { image_url: "https://example.com/shot.png" }, renderer_type: :image_diff)

    Mcp::Tools::SubmitReportTool.call(
      title: "Dashboard slowness",
      narrative: "It's slow because of an N+1 query.",
      findings: [ "N+1 query in DashboardController#index" ],
      references: [ { "type" => "dashboard_screenshot", "caption" => "The offending screen" } ],
      server_context: { run: run }
    )

    report = payload_for(job.reload)[:report]

    expect(report).to include(
      workflow_id: run.workflow_id,
      title: "Dashboard slowness",
      narrative: "It's slow because of an N+1 query.",
      findings: [ "N+1 query in DashboardController#index" ]
    )
    expect(report[:references]).to contain_exactly(
      include(
        type: "dashboard_screenshot",
        caption: "The offending screen",
        artifact: include(type: "dashboard_screenshot", title: "Dashboard screenshot", renderer_type: "image_diff")
      )
    )
  end

  it "does not populate report for a non-investigation job even with matching artifacts" do
    job = Factories.job(repository: repo, issue_number: 42)

    expect(payload_for(job)[:report]).to be_nil
  end
end
