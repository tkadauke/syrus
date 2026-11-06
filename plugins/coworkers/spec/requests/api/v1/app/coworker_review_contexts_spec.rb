require "rails_helper"

RSpec.describe "API: coworker review contexts", type: :request do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:workspace_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-review-evidence",
      workspace_repo: workspace_repository.remote_url)
  end
  let(:job) { Factories.job(user: owner, repository:) }
  let(:step) { Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99) }
  let(:run) { step.runs.create!(job:, trigger_kind: "initial", agent_provider: "codex", model: "test") }
  let(:evidence) do
    ReviewEvidence.create!(run:, workflow: run.workflow, step:, reviewer: coworker, review_kind: "coworker",
      provider: "codex", model: "test", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1")
  end
  let!(:review_context) do
    Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:,
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, exact_context: { "protected_prompt" => "restricted" },
      workspace_path: "/recoverable/reviewer/context")
  end

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "allows the owner to read exact context through the restricted endpoint and audits access" do
    sign_in_as(owner)
    get "/api/v1/app/coworkers/#{coworker.id}/review_contexts/#{run.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("exact_context" => { "protected_prompt" => "restricted" })
    expect(AdminAction.last).to have_attributes(action: "coworker_review_context_read")
  end

  it "denies an unrelated user without exposing restricted context" do
    sign_in_as(Factories.user(email_address: "unrelated-reviewer@example.com"))
    get "/api/v1/app/coworkers/#{coworker.id}/review_contexts/#{run.id}"

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("restricted")
  end

  it "authorizes before resolving restricted evidence" do
    sign_in_as(Factories.user(email_address: "another-reviewer@example.com"))
    get "/api/v1/app/coworkers/#{coworker.id}/review_contexts/999999"

    expect(response).to have_http_status(:forbidden)
  end
end
