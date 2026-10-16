require "rails_helper"

RSpec.describe "Agent Insights mutation tools" do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:server_context) { { chat_session: chat_session } }

  before do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)
  end

  def insight(**attrs)
    source_job = attrs.delete(:job) || Job.create!(user: user, repository: attrs[:repository] || repository, kind: "agent_insight", priority: "low")
    AgentInsights::Suggestion.create!({ job: source_job, repository: repository, title: "Finding", category: "configuration",
      severity: "low", confidence: 0.8 }.merge(attrs))
  end

  def insight_run
    job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
    workflow = Workflow.create!(job: job, trigger_kind: "agent_insight", agent_provider: user.agent_provider, chain_template: [])
    step = Step.create!(workflow: workflow, kind: "agent_insight_run", position: 0)
    step.runs.create!(job: job, trigger_kind: "agent_insight", agent_provider: user.agent_provider)
  end

  it "accepts a singular create-job insight with its proposal semantics" do
    target = insight(proposal_type: "create_job", suggested_prompt: "Fix the configuration drift")

    expect {
      response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: target.id, server_context: server_context)
      expect(response).not_to be_error
    }.to change(Job, :count).by(1)

    expect(target.reload).to be_accepted
    expect(target.created_job.issue_body).to eq("Fix the configuration drift")

    expect {
      retry_response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: target.id, server_context: server_context)
      expect(retry_response).not_to be_error
    }.not_to change(Job, :count)
  end

  it "accepts a save-memory insight exactly once across retries" do
    target = insight(proposal_type: "save_memory", memory_suggestion: "The repository uses an explicit runtime.")

    2.times do
      response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: target.id, server_context: server_context)
      expect(response).not_to be_error
    end

    expect(AgentMemory::Entry.where(source_type: "insight", source_id: target.id).count).to eq(1)
  end

  it "uses the owning user for run-scoped Job and memory side effects" do
    run = insight_run
    create_job = insight(job: run.job, proposal_type: "create_job", suggested_prompt: "Create run-scoped work")
    save_memory = insight(job: run.job, proposal_type: "save_memory", memory_suggestion: "Remember the run-scoped fact")

    job_response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: create_job.id, server_context: { run: run })
    memory_response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: save_memory.id, server_context: { run: run })

    expect(job_response).not_to be_error
    expect(memory_response).not_to be_error
    expect(create_job.reload.created_job.user).to eq(user)
    expect(AgentMemory::Entry.find_by!(source_type: "insight", source_id: save_memory.id).user).to eq(user)
  end

  it "retains the Run as the audit actor for run-scoped mutations" do
    run = insight_run
    target = insight(job: run.job)

    response = AgentInsights::Tools::DismissInsightTool.call(
      insight_id: target.id, reason: "Not actionable.", server_context: { run: run }
    )

    expect(response).not_to be_error
    event = target.audit_events.find_by!(event_type: "dismissed")
    expect(event.actor_run).to eq(run)
    expect(event.actor_user).to be_nil
  end

  it "deduplicates a batch and creates one grouped confirmation before changing records" do
    first = insight(title: "One")
    second = insight(title: "Two")

    response = AgentInsights::Tools::DismissInsightTool.call(
      insight_ids: [ first.id, second.id, first.id ], reason: "Not actionable.", server_context: server_context
    )
    payload = JSON.parse(response.content.first[:text])

    expect(payload.fetch("pending_action_group_id")).to be_present
    expect(first.reload).to be_pending
    expect(second.reload).to be_pending
    group = PendingActionGroup.find(payload.fetch("pending_action_group_id"))
    expect(group.chat_pending_actions.one?).to be(true)

    group.confirm_all!(user: user)
    expect([ first.reload.state, second.reload.state ]).to eq(%w[dismissed dismissed])
    expect(AgentInsights::AuditEvent.where(event_type: "dismissed").count).to eq(2)
  end

  it "redacts dismissal reasons before persisting or presenting a grouped action" do
    first = insight
    second = insight
    response = AgentInsights::Tools::DismissInsightTool.call(
      insight_ids: [ first.id, second.id ], reason: "Duplicate; token=supersecret", server_context: server_context
    )
    action = PendingActionGroup.find(JSON.parse(response.content.first[:text]).fetch("pending_action_group_id")).chat_pending_actions.first

    expect(action.payload.fetch("reason")).to eq("Duplicate; token=[REDACTED]")
    expect(PendingActions::DismissInsights.new(action).presentation_detail).to include("token=[REDACTED]")
    expect(action.payload.to_json).not_to include("supersecret")
  end

  it "redacts retirement reasons before persisting a grouped action" do
    first = insight
    second = insight
    response = AgentInsights::Tools::RetireInsightTool.call(
      insight_ids: [ first.id, second.id ], reason: "Stale; password=hunter2", server_context: server_context
    )
    action = PendingActionGroup.find(JSON.parse(response.content.first[:text]).fetch("pending_action_group_id")).chat_pending_actions.first

    expect(action.payload.fetch("reason")).to eq("Stale; password=[REDACTED]")
    expect(PendingActions::RetireInsights.new(action).presentation_detail).not_to include("hunter2")
  end

  it "rejects the whole batch before side effects when any target is ineligible" do
    eligible = insight(proposal_type: "create_job", suggested_prompt: "Create work")
    ineligible = insight(state: "dismissed", dismissed_at: Time.current)

    expect {
      response = AgentInsights::Tools::AcceptInsightTool.call(insight_ids: [ eligible.id, ineligible.id ], server_context: server_context)
      expect(response).to be_error
      expect(response.content.first[:text]).to include("must be pending")
    }.not_to change(Job, :count)
    expect(eligible.reload).to be_pending
    expect(chat_session.pending_actions).to be_empty
  end

  it "rolls back earlier side effects when a later acceptance side effect fails" do
    create_job = insight(proposal_type: "create_job", suggested_prompt: "Create work")
    save_memory = insight(proposal_type: "save_memory", memory_suggestion: "Remember this")
    response = AgentInsights::Tools::AcceptInsightTool.call(
      insight_ids: [ create_job.id, save_memory.id ], server_context: server_context
    )
    group = PendingActionGroup.find(JSON.parse(response.content.first[:text]).fetch("pending_action_group_id"))
    allow(AgentMemory::Entry).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

    expect { group.confirm_all!(user: user) }.not_to change(Job, :count)
    expect(create_job.reload).to be_pending
    expect(save_memory.reload).to be_pending
    expect(group.chat_pending_actions.first.reload).to be_failed
  end

  it "rejects inaccessible mixed-repository ids without leaking or mutating either target" do
    visible = insight
    other_user = Factories.user
    hidden_repository = Factories.repository(user: other_user)
    hidden_job = Job.create!(user: other_user, repository: hidden_repository, kind: "agent_insight", priority: "low")
    hidden = insight(job: hidden_job, repository: hidden_repository)

    response = AgentInsights::Tools::DismissInsightTool.call(
      insight_ids: [ visible.id, hidden.id ], reason: "Duplicate.", server_context: server_context
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("accessible insight")
    expect(visible.reload).to be_pending
    expect(hidden.reload).to be_pending
  end

  it "enforces the batch limit and exactly one id parameter" do
    response = AgentInsights::Tools::AcceptInsightTool.call(insight_ids: (1..51).to_a, server_context: server_context)
    expect(response).to be_error
    expect(response.content.first[:text]).to include("more than 50")

    target = insight
    response = AgentInsights::Tools::AcceptInsightTool.call(insight_id: target.id, insight_ids: [ target.id ], server_context: server_context)
    expect(response).to be_error
    expect(response.content.first[:text]).to include("provide only one")
  end

  it "rejects a grouped confirmation without changing records" do
    first = insight
    second = insight
    response = AgentInsights::Tools::RetireInsightTool.call(
      insight_ids: [ first.id, second.id ], reason: "Stale.", server_context: server_context
    )
    group = PendingActionGroup.find(JSON.parse(response.content.first[:text]).fetch("pending_action_group_id"))

    group.reject_all!(user: user)
    expect(first.reload).to be_pending
    expect(second.reload).to be_pending
  end
end
