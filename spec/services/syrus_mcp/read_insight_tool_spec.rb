require "rails_helper"

RSpec.describe SyrusMcp::ReadInsightTool do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:run)        { insight_run(user: user, repository: repository) }

  before do
    Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name     = "Agent Insights"
    end.update!(enabled: true)
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

  def create_insight(**attrs)
    InsightSuggestion.create!({
      job:        run.job,
      repository: repository,
      title:      "Default finding",
      category:   "repeated_failure",
      severity:   "high",
      confidence: 0.9
    }.merge(attrs))
  end

  def call(id:)
    described_class.call(id: id, server_context: { run: run })
  end

  def parsed_insight(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)[:insight]
  end

  describe "successful read" do
    let!(:insight) do
      create_insight(
        title:             "Prepare failures pattern",
        category:          "repeated_failure",
        severity:          "high",
        confidence:        0.95,
        suggested_prompt:  "Fix the Gemfile lock",
        memory_suggestion: "Prepare fails due to lock mismatch"
      )
    end

    it "returns a non-error response" do
      expect(call(id: insight.id)).not_to be_error
    end

    it "includes all full payload fields" do
      result = parsed_insight(call(id: insight.id))

      expect(result[:id]).to eq(insight.id)
      expect(result[:title]).to eq("Prepare failures pattern")
      expect(result[:category]).to eq("repeated_failure")
      expect(result[:severity]).to eq("high")
      expect(result[:confidence]).to be_within(0.001).of(0.95)
      expect(result[:state]).to eq("pending")
      expect(result[:suggested_prompt]).to eq("Fix the Gemfile lock")
      expect(result[:memory_suggestion]).to eq("Prepare fails due to lock mismatch")
      expect(result[:created_at]).to be_a(String)
      expect(result[:updated_at]).to be_a(String)
    end

    it "includes the associated job id and title" do
      result = parsed_insight(call(id: insight.id))

      expect(result[:job][:id]).to eq(run.job.id)
      expect(result[:job][:title]).to be_a(String)
    end

    it "returns nil evidence when none was provided" do
      result = parsed_insight(call(id: insight.id))
      expect(result[:evidence]).to be_nil
    end

    it "returns persisted evidence entries in the full payload" do
      evidence_run = Factories.job(user: user, repository: repository).initial_run
      insight.update!(evidence: [
        { "job_id" => evidence_run.job_id, "run_id" => evidence_run.id, "kind" => "grader" }
      ])

      result = parsed_insight(call(id: insight.id))

      expect(result[:evidence]).to eq([
        { job_id: evidence_run.job_id, run_id: evidence_run.id, kind: "grader" }
      ])
    end
  end

  describe "not found" do
    it "returns an error when the id does not exist" do
      response = call(id: 0)
      expect(response).to be_error
      expect(response.content.first[:text]).to include("insight not found or not accessible")
    end

    it "returns an error when the insight belongs to a different repository" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job  = Job.create!(user: other_user, repository: other_repo, kind: "agent_insight", priority: "low")

      foreign_insight = InsightSuggestion.create!(
        job: other_job, repository: other_repo,
        title: "Foreign finding", category: "config",
        severity: "low", confidence: 0.5
      )

      response = call(id: foreign_insight.id)
      expect(response).to be_error
      expect(response.content.first[:text]).to include("insight not found or not accessible")
    end
  end

  describe "chat context authorization" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    def chat_call(id:, session: chat_session)
      described_class.call(id: id, server_context: { chat_session: session })
    end

    it "reads an insight for a non-admin chat user's attached repository" do
      insight = create_insight(title: "Chat-visible finding")

      response = chat_call(id: insight.id)

      expect(response).not_to be_error
      expect(parsed_insight(response)[:title]).to eq("Chat-visible finding")
    end

    it "rejects an inaccessible insight id without exposing private fields" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Job.create!(user: other_user, repository: other_repo, kind: "agent_insight", priority: "low")
      foreign_insight = InsightSuggestion.create!(
        job: other_job,
        repository: other_repo,
        title: "Private finding title",
        category: "secret-category",
        severity: "low",
        confidence: 0.5,
        suggested_prompt: "Private prompt body",
        memory_suggestion: "Private memory body"
      )

      response = chat_call(id: foreign_insight.id)
      text = response.content.first[:text]

      expect(response).to be_error
      expect(text).to include("insight not found or not accessible")
      expect(text).not_to include("Private finding title", "secret-category", "Private prompt body", "Private memory body")
    end

    it "lets admin chat users read insights across repositories" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Job.create!(user: other_user, repository: other_repo, kind: "agent_insight", priority: "low")
      foreign_insight = InsightSuggestion.create!(
        job: other_job,
        repository: other_repo,
        title: "Admin-visible finding",
        category: "config",
        severity: "medium",
        confidence: 0.6
      )
      admin = Factories.user(admin: true)
      admin_session = ChatSession.create!(user: admin, repository: Factories.repository(user: admin))

      response = chat_call(id: foreign_insight.id, session: admin_session)

      expect(response).not_to be_error
      expect(parsed_insight(response)[:title]).to eq("Admin-visible finding")
    end
  end

  describe "feature flag gating" do
    it "is included in insight_tools when agent_insights flag is on" do
      context = McpToolContext.from_run(run)
      expect(McpToolPolicy.for(context)).to include(described_class)
    end

    it "is excluded from insight_tools when agent_insights flag is off" do
      # Materialize the run while the flag is still on, then disable it.
      eager_run = run
      Feature.find_by!(slug: "agent_insights").update!(enabled: false)
      Feature.clear_enabled_cache!("agent_insights")

      context = McpToolContext.from_run(eager_run)
      expect(McpToolPolicy.for(context)).not_to include(described_class)
    end
  end

  describe "tool schema" do
    it "exposes the expected tool name" do
      expect(described_class.tool_name).to eq("read_insight")
    end

    it "requires id" do
      expect(described_class.input_schema_value.to_h[:required]).to include("id")
    end
  end
end
