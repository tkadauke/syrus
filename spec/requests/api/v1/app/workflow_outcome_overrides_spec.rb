require "rails_helper"

RSpec.describe "workflow outcome overrides", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job(user:, repository:) }
  let(:workflow) { job.workflows.last }
  let!(:grader) do
    Step.create!(workflow:, kind: "grader", position: 10, state: "failed", details: {
      "name" => "lint", "required" => true, "technically_overridable" => true,
      "command" => "bin/lint", "exit_code" => 1, "output" => "false positive"
    })
  end

  before do
    sign_in_as(user)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "a" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "plan-v1")
  end

  it "lists exact evidence and records a reasoned UI confirmation for a non-admin operator" do
    get "/api/v1/app/jobs/#{job.id}/workflow_outcome_overrides"
    expect(response).to have_http_status(:ok)
    candidate = JSON.parse(response.body).fetch("candidates").sole
    expect(candidate).to include("policy" => "ask", "gate_kind" => "implementation_grader")

    post "/api/v1/app/jobs/#{job.id}/workflow_outcome_overrides", params: {
      fingerprint_digest: candidate.fetch("fingerprint_digest"), reason: "Known false-positive check"
    }

    expect(response).to have_http_status(:created)
    expect(WorkflowOutcomeOverride.last).to have_attributes(actor: user, channel: "ui", reason: "Known false-positive check")
    expect(WorkflowOutcomeOverride.last.permission_decision).to include("confirmation" => "explicit_ui_confirmation")
  end

  it "refuses stale evidence" do
    post "/api/v1/app/jobs/#{job.id}/workflow_outcome_overrides", params: {
      fingerprint_digest: "stale", reason: "No longer exact"
    }
    expect(response).to have_http_status(:conflict)
  end
end
