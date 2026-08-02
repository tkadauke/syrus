require "rails_helper"

RSpec.describe SyrusMcp::SubmitInsightTool do
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
    defaults = {
      title:      "Repeated prepare failures on main",
      category:   "repeated_failure",
      severity:   "high",
      confidence: 0.9
    }
    described_class.call(**defaults.merge(overrides), server_context: { run: run })
  end

  # Creates an agent_insight Job + Workflow + Step + Run for testing.
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

  describe "successful submission" do
    it "creates an InsightSuggestion record" do
      expect { call }.to change(InsightSuggestion, :count).by(1)
    end

    it "persists all provided fields" do
      call(
        title:             "Repeated prepare failures",
        category:          "repeated_failure",
        severity:          "high",
        confidence:        0.85,
        suggested_prompt:  "Fix the Gemfile lock",
        memory_suggestion: "Prepare sometimes fails due to lock mismatch"
      )

      suggestion = InsightSuggestion.last
      expect(suggestion.title).to eq("Repeated prepare failures")
      expect(suggestion.category).to eq("repeated_failure")
      expect(suggestion.severity).to eq("high")
      expect(suggestion.confidence).to be_within(0.001).of(0.85)
      expect(suggestion.suggested_prompt).to eq("Fix the Gemfile lock")
      expect(suggestion.memory_suggestion).to eq("Prepare sometimes fails due to lock mismatch")
      expect(suggestion.effective_proposal_type).to eq("create_job")
      expect(suggestion.state).to eq("pending")
      expect(suggestion.job).to eq(run.job)
      expect(suggestion.repository).to eq(repository)
    end

    it "appends a summary to the workflow insights artifact" do
      call(title: "My finding", category: "inefficiency", severity: "low", confidence: 0.6)

      suggestion = InsightSuggestion.last
      insights = run.workflow.reload.artifact("insights")
      expect(insights).to be_an(Array)
      expect(insights.last).to include(
        "id"       => suggestion.id,
        "title"    => "My finding",
        "category" => "inefficiency",
        "severity" => "low"
      )
    end

    it "publishes a supervisor event for the new insight" do
      allow(SupervisorEvents).to receive(:publish!)

      call(title: "High-value finding", category: "configuration", severity: "high", confidence: 0.91)

      suggestion = InsightSuggestion.last
      expect(SupervisorEvents).to have_received(:publish!).with(
        kind: "agent_insight_available",
        severity: "warning",
        subject: "Agent Insight available",
        repository: repository,
        job: run.job,
        actor: run,
        summary: "High-value finding (high, 91% confidence)",
        details: {
          "insight_suggestion_id" => suggestion.id,
          "job_id" => run.job_id,
          "run_id" => run.id,
          "category" => "configuration"
        },
        dedupe_key: "agent_insight_available:#{suggestion.id}"
      )
    end

    it "appends multiple insights to the same workflow artifact" do
      call(title: "Finding 1", category: "config", severity: "medium", confidence: 0.7)
      call(title: "Finding 2", category: "config", severity: "low",    confidence: 0.5)

      insights = run.workflow.reload.artifact("insights")
      expect(insights.size).to eq(2)
    end

    it "writes a JobLog audit line" do
      expect { call }.to change { run.job_logs.count }.by(1)
      expect(run.job_logs.last.chunk).to include("[mcp] submit_insight:")
    end

    it "returns a success response with the suggestion id" do
      response = call

      expect(response).not_to be_error
      expect(response.content.first[:text]).to match(/InsightSuggestion #\d+ saved\./)
    end

    it "accepts evidence referencing jobs owned by the user" do
      other_job = Factories.job(user: user, repository: repository)

      response = call(evidence: [ { "job_id" => other_job.id, "run_id" => nil, "kind" => "issue" } ])

      expect(response).not_to be_error
      expect(InsightSuggestion.last.evidence).to be_an(Array)
    end
  end

  describe "validation failures" do
    it "rejects blank title" do
      response = call(title: "  ")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("title is required")
    end

    it "rejects title over 200 characters" do
      response = call(title: "x" * 201)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("title too long")
    end

    it "rejects blank category" do
      response = call(category: "")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("category is required")
    end

    it "rejects invalid severity" do
      response = call(severity: "critical")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("severity must be one of")
    end

    it "rejects confidence below 0.0" do
      response = call(confidence: -0.1)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("confidence must be between 0.0 and 1.0")
    end

    it "rejects confidence above 1.0" do
      response = call(confidence: 1.1)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("confidence must be between 0.0 and 1.0")
    end
  end

  describe "scope enforcement — cross-repo reads rejected for non-admin" do
    let(:other_user)       { Factories.user }
    let(:other_repository) { Factories.repository(user: other_user) }

    it "rejects evidence referencing a job from another user's repository" do
      user.update!(admin: false)
      foreign_job = Factories.job(user: other_user, repository: other_repository)

      response = call(
        evidence: [ { "job_id" => foreign_job.id, "kind" => "issue" } ]
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("evidence references jobs not accessible to this user")
    end

    it "allows evidence referencing foreign jobs when user is admin" do
      user.update!(admin: true)
      foreign_job = Factories.job(user: other_user, repository: other_repository)

      response = call(
        evidence: [ { "job_id" => foreign_job.id, "kind" => "issue" } ]
      )

      expect(response).not_to be_error
    end

    it "allows nil or empty evidence without scope error" do
      expect(call(evidence: nil)).not_to be_error
      expect(call(evidence: [])).not_to be_error
    end
  end

  describe "feature flag gating" do
    it "is excluded from insight_tools when agent_insights flag is off" do
      # Materialize the run while the flag is still on, then disable it.
      eager_run = run
      Feature.find_by!(slug: "agent_insights").update!(enabled: false)
      Feature.clear_enabled_cache!("agent_insights")

      context = McpToolContext.from_run(eager_run)
      tools = McpToolPolicy.for(context)

      expect(tools).not_to include(described_class)
    end

    it "is included in insight_tools when agent_insights flag is on" do
      context = McpToolContext.from_run(run)
      tools = McpToolPolicy.for(context)

      expect(tools).to include(described_class)
    end
  end

  describe "suggestion type contract" do
    it "stores only suggested_prompt (no memory_suggestion) for a pure code-bug finding" do
      call(
        title:            "Missing constant in failure classifier",
        category:         "configuration",
        severity:         "high",
        confidence:       0.95,
        suggested_prompt: "Add the missing TRANSIENT_ERRORS constant to RunFailureClassifier",
        memory_suggestion: nil
      )

      suggestion = InsightSuggestion.last
      expect(suggestion.suggested_prompt).to be_present
      expect(suggestion.memory_suggestion).to be_nil
    end

    it "stores both suggested_prompt and memory_suggestion when a fix is in flight with interim context" do
      call(
        title:             "Prepare step fails when vendor/bundle is stale",
        category:          "repeated_failure",
        severity:          "medium",
        confidence:        0.8,
        suggested_prompt:  "Fix the Gemfile lock to unblock prepare",
        memory_suggestion: "Prepare may fail on stale vendor/bundle until lock fix lands; run `bundle install` manually as a workaround"
      )

      suggestion = InsightSuggestion.last
      expect(suggestion.suggested_prompt).to be_present
      expect(suggestion.memory_suggestion).to be_present
    end

    it "stores only memory_suggestion (no suggested_prompt) for a durable behavioral pattern" do
      call(
        title:             "Agent always over-fetches GitHub API for issue metadata",
        category:          "inefficiency",
        severity:          "low",
        confidence:        0.75,
        suggested_prompt:  nil,
        memory_suggestion: "GitHub issue metadata is already included in the Syrus job context; do not re-fetch it via the API"
      )

      suggestion = InsightSuggestion.last
      expect(suggestion.suggested_prompt).to be_nil
      expect(suggestion.memory_suggestion).to be_present
    end

    it "stores remove_memory proposals without deleting the target memory" do
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "The flaky spec is still broken."
      )

      response = call(
        title: "Remove fixed-bug memory",
        category: "memory_stale",
        severity: "medium",
        confidence: 0.9,
        proposal_type: "remove_memory",
        target_memory_id: memory.id,
        stale_memory_text: memory.content,
        stale_memory_evidence: "The spec was fixed in JOB-200 and now passes."
      )

      expect(response).not_to be_error
      suggestion = InsightSuggestion.last
      expect(suggestion.effective_proposal_type).to eq("remove_memory")
      expect(suggestion.target_memory).to eq(memory)
      expect(suggestion.stale_memory_evidence).to include("JOB-200")
      expect(memory.reload.deleted_at).to be_nil
    end

    it "rejects remove_memory proposals for inaccessible memories" do
      user.update!(admin: false)
      other_repo = Factories.repository(user: user)
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: other_repo.id,
        content: "Other repo memory."
      )

      response = call(
        proposal_type: "remove_memory",
        target_memory_id: memory.id,
        stale_memory_evidence: "Not true anymore."
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("target_memory_id")
    end
  end

  describe "tool schema" do
    it "exposes the expected tool name" do
      expect(described_class.tool_name).to eq("submit_insight")
    end

    it "declares all expected required fields" do
      expect(described_class.input_schema_value.to_h[:required]).to match_array(%w[title category severity confidence])
    end
  end
end
