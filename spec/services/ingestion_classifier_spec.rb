require "rails_helper"
require "ostruct"

RSpec.describe IngestionClassifier do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:github_client) { instance_double(GithubClient, list_pull_requests_for_triage: []) }

  def agent_returning(json)
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: JSON.generate(json),
      session_id: nil
    )
    instance_double("ClassifierAgent", run_once: result)
  end

  def classify(job, json, client: github_client)
    described_class.call(job: job, agent: agent_returning(json), github_client: client)
  end

  it "marks a duplicate issue invalid with the original issue URL as evidence" do
    original = Job.create!(
      user: user,
      repository: repository,
      issue_number: 10,
      issue_title: "Add status filters",
      issue_body: "Let operators filter the dashboard by run status."
    )
    original.advance_after_triage!
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 11,
      issue_title: "Dashboard status filters",
      issue_body: "Add filters so operators can filter by run status."
    )
    evidence_url = "https://github.com/acme/widgets/issues/10"

    classify(job, {
      "epic_id" => nil,
      "invalid" => {
        "kind" => "duplicate",
        "reason" => "This matches the existing status-filter Job.",
        "evidence_urls" => [ evidence_url ]
      }
    })

    expect(job.reload).to have_attributes(
      state: "closed",
      closure_reason: "duplicate",
      validity: "duplicate",
      invalidation_reason: "This matches the existing status-filter Job.",
      invalidation_evidence: [ evidence_url ]
    )
    expect(job.runs).to be_empty
  end

  it "marks already-implemented issues invalid with merged PR evidence" do
    pr = OpenStruct.new(
      number: 32,
      title: "Ship status filters",
      body: "Adds dashboard filters.",
      html_url: "https://github.com/acme/widgets/pull/32",
      merged_at: 2.days.ago
    )
    client = instance_double(GithubClient, list_pull_requests_for_triage: [ pr ])
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 12,
      issue_title: "Add status filters",
      issue_body: "Operators need dashboard filters."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => {
        "kind" => "already_implemented",
        "reason" => "PR #32 already added dashboard status filters.",
        "evidence_urls" => [ "https://github.com/acme/widgets/pull/32" ]
      }
    }, client: client)

    expect(job.reload).to have_attributes(
      state: "closed",
      closure_reason: "already_implemented",
      validity: "already_implemented",
      invalidation_evidence: [ "https://github.com/acme/widgets/pull/32" ]
    )
  end

  it "assigns a strong Epic match and advances through the normal triage flow" do
    epic = Factories.epic(user: user, repository: repository, state: "backlog", title: "Dashboard cleanup")
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 13,
      issue_title: "Add status filters",
      issue_body: "This belongs with the dashboard cleanup work."
    )

    classify(job, {
      "epic_id" => epic.id,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    })

    expect(job.reload.epic).to eq(epic)
    expect(job.state).to eq("blocked_by_epic")
    expect(job.runs).to be_empty
  end

  it "queues a clear novel issue through the normal triage flow" do
    job = Job.create!(
      user: user,
      repository: repository,
      issue_number: 14,
      issue_title: "Add a new report",
      issue_body: "Build a novel operator report."
    )

    classify(job, {
      "epic_id" => nil,
      "invalid" => { "kind" => nil, "reason" => "", "evidence_urls" => [] }
    })

    expect(job.reload.state).to eq("queued")
    expect(job.validity).to eq("valid")
    expect(job.runs.count).to eq(1)
  end

  it "marks classifier failures as uncertain without queueing the job" do
    job = Job.create!(user: user, repository: repository, issue_number: 15)
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "not json",
      session_id: nil
    )
    agent = instance_double("ClassifierAgent", run_once: result)

    described_class.call(job: job, agent: agent, github_client: github_client)

    expect(job.reload).to be_triaging
    expect(job.triaging_reason).to eq("classifier_uncertain")
    expect(job.runs).to be_empty
  end
end
