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

  it "lets the owner read only the durable journal entry through an audited endpoint" do
    review_context.update!(persistence_state: "persisted", persisted_commit_sha: "d" * 40)
    stub_repository_content(workspace_repository, ref: "coworkers/#{coworker.handle}",
      files: { "reviews/journal/evidence-#{evidence.id}.md" => "# Repository review\nVerdict: approved\n" })
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/review_journal/#{run.id}"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("content" => include("Verdict: approved"),
      "path" => "reviews/journal/evidence-#{evidence.id}.md", "persisted_commit_sha" => "d" * 40)
    expect(response.body).not_to include("restricted")
    expect(AdminAction.last).to have_attributes(action: "coworker_review_journal_read")
  end

  it "lets an admin inspect another owner's durable journal and audits the access" do
    stub_repository_content(workspace_repository, ref: "coworkers/#{coworker.handle}",
      files: { "reviews/journal/evidence-#{evidence.id}.md" => "Verdict: approved\n" })
    sign_in_as(Factories.user(admin: true, email_address: "review-admin@example.com"))

    get "/api/v1/app/coworkers/#{coworker.id}/review_journal/#{run.id}"

    expect(response).to have_http_status(:ok)
    expect(AdminAction.last).to have_attributes(action: "coworker_review_journal_read")
  end

  it "denies an unrelated user journal access before resolving the Run" do
    sign_in_as(Factories.user(email_address: "unrelated-journal-reader@example.com"))

    get "/api/v1/app/coworkers/#{coworker.id}/review_journal/999999"

    expect(response).to have_http_status(:forbidden)
  end

  it "returns not found when the coworker has no readable workspace repository" do
    coworker.update!(workspace_repo: "https://example.test/unavailable.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers/#{coworker.id}/review_journal/#{run.id}"

    expect(response).to have_http_status(:not_found)
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
