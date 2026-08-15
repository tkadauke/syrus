require "rails_helper"

RSpec.describe Mcp::Tools::RetireInsightTool do
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
      reason: overrides.delete(:reason) { "Duplicated by a newer finding." },
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

  it "retires a pending insight and records an audit event with run actor context" do
    target = insight

    expect {
      response = call(target_insight_id: target.id, reason: "Superseded by a broader finding.")
      expect(response).not_to be_error
    }.to change(InsightSuggestionAuditEvent, :count).by(1)

    target.reload
    expect(target.state).to eq("retired")
    expect(target.retired_at).to be_present
    expect(target.retired_reason).to eq("Superseded by a broader finding.")

    event = InsightSuggestionAuditEvent.last
    expect(event.insight_suggestion).to eq(target)
    expect(event.event_type).to eq("retired")
    expect(event.actor_kind).to eq("agent")
    expect(event.actor_run).to eq(run)
    expect(event.reason).to eq("Superseded by a broader finding.")
  end

  it "retires a dismissed insight" do
    target = insight(state: "dismissed", dismissed_at: 1.hour.ago)

    response = call(target_insight_id: target.id)

    expect(response).not_to be_error
    expect(target.reload.state).to eq("retired")
  end

  it "records superseded_by_insight_id and superseded_by_job_id when given" do
    target = insight
    superseding = insight(title: "Newer finding")
    superseding_job = Factories.job(user: user, repository: repository)

    response = call(
      target_insight_id: target.id,
      superseded_by_insight_id: superseding.id,
      superseded_by_job_id: superseding_job.id
    )

    expect(response).not_to be_error
    target.reload
    expect(target.superseded_by_insight_id).to eq(superseding.id)
    expect(target.superseded_by_job_id).to eq(superseding_job.id)
  end

  it "rejects accepted insights by default with guidance to file a new insight" do
    target = insight(state: "accepted", accepted_at: 1.hour.ago)

    response = call(target_insight_id: target.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("accepted and cannot be retired")
    expect(target.reload.state).to eq("accepted")
  end

  it "retires an accepted insight when retire_accepted is true" do
    target = insight(state: "accepted", accepted_at: 1.hour.ago)

    response = call(target_insight_id: target.id, retire_accepted: true)

    expect(response).not_to be_error
    expect(target.reload.state).to eq("retired")
  end

  it "rejects an already retired insight" do
    target = insight
    target.retire!(reason: "First retirement.", actor: nil)

    response = call(target_insight_id: target.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("already retired")
  end

  it "rejects a missing reason" do
    target = insight

    response = call(target_insight_id: target.id, reason: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("reason is required")
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

    response = call(target_insight_id: foreign.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("target_insight_id must reference an accessible insight")
  end

  it "rejects superseded_by_insight_id referencing an insight outside the current repository" do
    target = insight
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

    response = call(target_insight_id: target.id, superseded_by_insight_id: foreign.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("superseded_by_insight_id must reference an accessible insight")
  end

  it "rejects superseded_by_insight_id referencing itself" do
    target = insight

    response = call(target_insight_id: target.id, superseded_by_insight_id: target.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("cannot reference the insight being retired")
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
