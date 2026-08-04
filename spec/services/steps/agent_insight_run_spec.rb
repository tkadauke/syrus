require "rails_helper"
require "tmpdir"

RSpec.describe Steps::AgentInsightRun do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name     = "Agent Insights"
    end.update!(enabled: true)

    Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
  end
  let(:workflow) { Workflows::AgentInsight.instantiate(job: job) }
  let(:step)     { workflow.steps.find_by!(kind: "agent_insight_run") }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-agent-insight-run") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
  end

  describe "prompt building" do
    context "when no prior agent_insight job exists" do
      it "omits the analysis window from the prompt" do
        handler.call
        expect(run.reload.prompt).not_to include("Analysis Window")
      end

      it "persists a prompt on the run" do
        handler.call
        expect(run.reload.prompt).to be_present
      end
    end

    context "when a prior agent_insight job exists" do
      let!(:prior_job) do
        prior = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
        prior.update_columns(
          state: "closed",
          finished_at: Time.utc(2026, 7, 20, 12, 0, 0),
          closure_reason: "agent_insight"
        )
        prior
      end

      it "includes the analysis window in the prompt using the prior job finished_at" do
        handler.call
        expect(run.reload.prompt).to include("Analysis Window")
        expect(run.reload.prompt).to include("2026-07-20T12:00:00Z")
      end

      it "does not treat the current job as the prior job" do
        # Only one prior job exists; it must be the one just created, not job itself
        handler.call
        expect(run.reload.prompt).to include("2026-07-20T12:00:00Z")
      end
    end

    context "when the prior agent_insight job has no finished_at" do
      let!(:prior_job) do
        Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
        # prior_job is still queued, finished_at is nil
      end

      it "omits the analysis window from the prompt" do
        handler.call
        expect(run.reload.prompt).not_to include("Analysis Window")
      end
    end

    context "known insights" do
      let!(:accepted_insight) do
        InsightSuggestion.create!(
          job: job,
          repository: repository,
          title: "Agent repeatedly fails at rebase step",
          category: "repeated_failure",
          severity: "high",
          confidence: 0.9,
          state: "accepted"
        )
      end
      let!(:dismissed_insight) do
        InsightSuggestion.create!(
          job: job,
          repository: repository,
          title: "Memory gap for test runner config",
          category: "memory_gap",
          severity: "medium",
          confidence: 0.7,
          state: "dismissed"
        )
      end

      it "includes accepted insight titles in the prompt" do
        handler.call
        expect(run.reload.prompt).to include("Agent repeatedly fails at rebase step (accepted, informational)")
      end

      it "includes dismissed insight titles in the prompt" do
        handler.call
        expect(run.reload.prompt).to include("Memory gap for test runner config (dismissed, informational)")
      end

      it "includes pending insights in the prompt for freshness review" do
        pending_insight = InsightSuggestion.create!(
          job: job,
          repository: repository,
          title: "Pending finding nobody acted on",
          category: "inefficiency",
          severity: "low",
          confidence: 0.5,
          state: "pending"
        )
        handler.call
        expect(run.reload.prompt).to include("Pending finding nobody acted on (pending")
      end

      context "when insights belong to a different repository" do
        let(:other_repo) { Factories.repository(user: user) }
        let!(:other_job)  { Factories.job_record(repository: other_repo, state: "closed") }
        let!(:other_insight) do
          InsightSuggestion.create!(
            job: other_job,
            repository: other_repo,
            title: "Other repository finding",
            category: "configuration",
            severity: "low",
            confidence: 0.6,
            state: "accepted"
          )
        end

        it "does not include insights from other repositories" do
          handler.call
          expect(run.reload.prompt).not_to include("Other repository finding")
        end
      end

      it "lists known insights newest-first across pending, accepted, and dismissed states" do
        accepted_insight.update!(updated_at: 3.hours.ago)
        dismissed_insight.update!(updated_at: 2.hours.ago)
        pending_insight = InsightSuggestion.create!(
          job: job,
          repository: repository,
          title: "Pending finding nobody acted on",
          category: "inefficiency",
          severity: "low",
          confidence: 0.5,
          state: "pending",
          updated_at: 1.hour.ago
        )
        handler.call
        prompt = run.reload.prompt
        pending_pos = prompt.index("#{pending_insight.title} (pending, informational)")
        accepted_pos  = prompt.index("Agent repeatedly fails at rebase step")
        dismissed_pos = prompt.index("Memory gap for test runner config")
        expect(pending_pos).to be < accepted_pos
        expect(dismissed_pos).to be < accepted_pos
      end

      it "budgets enough room to include more than twenty-five pending insights" do
        26.times do |index|
          InsightSuggestion.create!(
            job: job,
            repository: repository,
            title: "Pending insight #{index}",
            category: "inefficiency",
            severity: "low",
            confidence: 0.5,
            state: "pending"
          )
        end

        handler.call

        expect(run.reload.prompt).to include("Pending insight 25 (pending, informational)")
      end
    end

    it "does not re-build the prompt if already persisted on the run" do
      run.update!(prompt: "pre-existing prompt")
      handler.call
      expect(run.reload.prompt).to eq("pre-existing prompt")
    end
  end
end
