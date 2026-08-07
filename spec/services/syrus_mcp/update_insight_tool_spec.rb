require "rails_helper"

RSpec.describe Mcp::Tools::UpdateInsightTool do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:run)        { insight_run(user: user, repository: repository) }

  before do
    Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name     = "Agent Insights"
    end.update!(enabled: true)
  end

  def call(**overrides)
    described_class.call(
      target_insight_id: overrides.delete(:target_insight_id),
      reason: overrides.delete(:reason) { "Current evidence supersedes the pending card." },
      **overrides,
      server_context: { run: run }
    )
  end

  def insight_run(user:, repository:)
    job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "agent_insight",
      agent_provider: user.agent_provider,
      chain_template: []
    )
    step = Step.create!(workflow: workflow, kind: "agent_insight_run", position: 0)
    step.runs.create!(job: job, trigger_kind: "agent_insight", agent_provider: user.agent_provider)
  end

  def insight(**attrs)
    InsightSuggestion.create!({
      job: run.job,
      repository: repository,
      title: "Old prepare finding",
      category: "configuration",
      severity: "low",
      confidence: 0.4
    }.merge(attrs))
  end

  it "updates a pending insight in place without creating a new row" do
    target = insight

    expect {
      response = call(
        target_insight_id: target.id,
        title: "Updated prepare finding",
        severity: "medium",
        confidence: 0.82,
        evidence: [ { "job_id" => run.job_id, "run_id" => run.id, "kind" => "agent_insight" } ],
        suggested_prompt: "Fix the repository prepare configuration",
        proposal_type: "create_job"
      )
      expect(response).not_to be_error
    }.not_to change(InsightSuggestion, :count)

    target.reload
    expect(target.title).to eq("Updated prepare finding")
    expect(target.severity).to eq("medium")
    expect(target.confidence).to be_within(0.001).of(0.82)
    expect(target.suggested_prompt).to eq("Fix the repository prepare configuration")
    expect(target.evidence).to eq([
      { "job_id" => run.job_id, "run_id" => run.id, "kind" => "agent_insight" }
    ])
  end

  it "allows dismissed but unaccepted insights to be updated" do
    target = insight(state: "dismissed", dismissed_at: 1.hour.ago)

    response = call(target_insight_id: target.id, title: "Dismissed insight is now clearer")

    expect(response).not_to be_error
    expect(target.reload.title).to eq("Dismissed insight is now clearer")
    expect(target.state).to eq("dismissed")
  end

  it "rejects accepted insight updates with guidance to submit a new insight" do
    target = insight(state: "accepted", accepted_at: 1.hour.ago)

    response = call(target_insight_id: target.id, title: "Should not change")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("accepted and cannot be updated")
    expect(response.content.first[:text]).to include("Submit a new insight")
    expect(target.reload.title).to eq("Old prepare finding")
  end

  it "records an audit event with previous and new values plus run actor context" do
    target = insight

    expect {
      call(target_insight_id: target.id, title: "Audited update", severity: "high", reason: "Merged with a newer duplicate.")
    }.to change(InsightSuggestionAuditEvent, :count).by(1)

    event = InsightSuggestionAuditEvent.last
    expect(event.insight_suggestion).to eq(target)
    expect(event.event_type).to eq("updated")
    expect(event.actor_kind).to eq("agent")
    expect(event.actor_run).to eq(run)
    expect(event.reason).to eq("Merged with a newer duplicate.")
    expect(event.previous_values).to include("title" => "Old prepare finding", "severity" => "low")
    expect(event.new_values).to include("title" => "Audited update", "severity" => "high")
  end

  it "rejects inaccessible target insights from another repository" do
    other_repo = Factories.repository(user: user)
    other_job = Job.create!(user: user, repository: other_repo, kind: "agent_insight", priority: "low")
    foreign = InsightSuggestion.create!(
      job: other_job,
      repository: other_repo,
      title: "Foreign",
      category: "configuration",
      severity: "low",
      confidence: 0.5
    )

    response = call(target_insight_id: foreign.id, title: "Nope")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("target_insight_id must reference an accessible insight")
  end

  it "rejects revise_existing_insight as an updated proposal type" do
    target = insight

    response = call(target_insight_id: target.id, proposal_type: "revise_existing_insight")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("proposal_type must be one of")
  end

  it "is available to agent insight runs when the feature flag is enabled" do
    context = McpToolContext.from_run(run)

    expect(McpToolPolicy.for(context)).to include(described_class)
  end

  it "is not available to agent insight runs when the feature flag is disabled" do
    eager_run = run
    Feature.find_by!(slug: "agent_insights").update!(enabled: false)
    Feature.clear_enabled_cache!("agent_insights")

    context = McpToolContext.from_run(eager_run)

    expect(McpToolPolicy.for(context)).not_to include(described_class)
  end
end
