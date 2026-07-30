require "rails_helper"

RSpec.describe SyrusMcp::ListInsightsTool do
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
      severity:   "medium",
      confidence: 0.8
    }.merge(attrs))
  end

  def call(**params)
    described_class.call(**params, server_context: { run: run })
  end

  def parsed_response(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  describe "basic listing" do
    it "returns an empty insights array when there are no records" do
      response = call
      expect(response).not_to be_error
      expect(parsed_response(response)[:insights]).to eq([])
    end

    it "returns all insights for the repository" do
      create_insight(title: "Finding A")
      create_insight(title: "Finding B")

      response = call
      titles = parsed_response(response)[:insights].map { |i| i[:title] }
      expect(titles).to contain_exactly("Finding A", "Finding B")
    end

    it "returns the expected list payload fields" do
      create_insight(title: "Scoped finding", severity: "high", confidence: 0.9)

      result = parsed_response(call)[:insights].first
      expect(result.keys).to match_array(%i[id title state severity confidence created_at])
    end

    it "orders results newest-first" do
      older = create_insight(title: "Older finding")
      newer = create_insight(title: "Newer finding")

      ids = parsed_response(call)[:insights].map { |i| i[:id] }
      expect(ids).to eq([ newer.id, older.id ])
    end
  end

  describe "state filtering" do
    before do
      create_insight(title: "Pending one")
      dismissed = create_insight(title: "Dismissed one")
      dismissed.dismiss!
    end

    it "returns only pending insights when state=pending" do
      response = call(state: "pending")
      titles = parsed_response(response)[:insights].map { |i| i[:title] }
      expect(titles).to eq(["Pending one"])
    end

    it "returns only dismissed insights when state=dismissed" do
      response = call(state: "dismissed")
      titles = parsed_response(response)[:insights].map { |i| i[:title] }
      expect(titles).to eq(["Dismissed one"])
    end

    it "returns all insights when state=all" do
      response = call(state: "all")
      expect(parsed_response(response)[:insights].size).to eq(2)
    end

    it "defaults to all when state is omitted" do
      response = call
      expect(parsed_response(response)[:insights].size).to eq(2)
    end

    it "returns an error for an invalid state" do
      response = call(state: "unknown")
      expect(response).to be_error
      expect(response.content.first[:text]).to include("state must be one of")
    end
  end

  describe "pagination" do
    before do
      5.times { |i| create_insight(title: "Finding #{i}") }
    end

    it "respects the limit parameter" do
      response = call(limit: 2)
      expect(parsed_response(response)[:insights].size).to eq(2)
    end

    it "returns a different page with the page parameter" do
      all_ids  = parsed_response(call(limit: 5))[:insights].map { |i| i[:id] }
      page1    = parsed_response(call(limit: 3, page: 1))[:insights].map { |i| i[:id] }
      page2    = parsed_response(call(limit: 3, page: 2))[:insights].map { |i| i[:id] }

      expect(page1 + page2).to match_array(all_ids)
    end

    it "clamps limit to the maximum of 50" do
      response = call(limit: 999)
      expect(response).not_to be_error
    end

    it "defaults to page 1 when page is omitted" do
      first_page  = parsed_response(call(limit: 3, page: 1))[:insights].map { |i| i[:id] }
      default_page = parsed_response(call(limit: 3))[:insights].map { |i| i[:id] }
      expect(default_page).to eq(first_page)
    end
  end

  describe "repository scope enforcement" do
    let(:other_user)       { Factories.user }
    let(:other_repository) { Factories.repository(user: other_user) }

    it "does not expose insights from a different repository" do
      own_insight = create_insight(title: "Own repo finding")

      other_job = Job.create!(user: other_user, repository: other_repository, kind: "agent_insight", priority: "low")
      InsightSuggestion.create!(
        job: other_job, repository: other_repository,
        title: "Other repo finding", category: "config",
        severity: "low", confidence: 0.5
      )

      response = call
      titles = parsed_response(response)[:insights].map { |i| i[:title] }
      expect(titles).to eq([ own_insight.title ])
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
      expect(described_class.tool_name).to eq("list_insights")
    end

    it "declares state, limit, and page as optional parameters" do
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to be_nil.or(be_empty)
      expect(schema[:properties].keys.map(&:to_s)).to include("state", "limit", "page")
    end
  end
end
