require "rails_helper"

RSpec.describe Prompts::AgentInsight do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def prompt(**overrides)
    described_class.new(repository: repository, **overrides).to_s
  end

  it "identifies the target repository in the header" do
    expect(prompt).to include(repository.slug)
  end

  it "includes the submit_insight tool name in instructions" do
    expect(prompt).to include("submit_insight")
  end

  it "includes all required submit_insight fields" do
    output = prompt
    expect(output).to include("title")
    expect(output).to include("category")
    expect(output).to include("severity")
    expect(output).to include("confidence")
  end

  describe "suggestion type rules" do
    it "instructs the agent to set suggested_prompt for code defects requiring a fix" do
      output = prompt
      expect(output).to include("suggested_prompt")
      expect(output).to match(/code defect|code change/i)
    end

    it "instructs the agent to set memory_suggestion for durable behavioral patterns" do
      output = prompt
      expect(output).to include("memory_suggestion")
      expect(output).to match(/behavioral pattern|durable/i)
    end

    it "instructs the agent to file both when a fix is in flight and interim context is needed" do
      output = prompt
      expect(output).to match(/file both|both.*suggested_prompt.*memory_suggestion/im)
    end

    it "explicitly forbids memory_suggestion for a pure code bug with a clear fix" do
      output = prompt
      expect(output).to match(/do not file a memory suggestion.*code bug|purely.*code bug.*do not/im)
    end

    it "states that a memory for a bug-about-to-be-fixed misleads future agents" do
      output = prompt
      expect(output).to match(/misleads?\s+future agents/i)
    end
  end

  describe "analysis window" do
    context "when analysis_window_start is provided" do
      let(:window_start) { Time.utc(2026, 7, 15, 10, 30, 0) }

      it "includes an Analysis Window section" do
        out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
        expect(out).to include("## Analysis Window")
      end

      it "includes the ISO 8601 timestamp" do
        out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
        expect(out).to include("2026-07-15T10:30:00Z")
      end

      it "instructs the agent not to re-examine earlier transcripts" do
        out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
        expect(out).to include("Do not re-examine transcripts from earlier runs")
      end
    end

    context "when analysis_window_start is nil" do
      it "omits the Analysis Window section" do
        out = described_class.new(repository: repository).to_s
        expect(out).not_to include("Analysis Window")
        expect(out).not_to include("Do not re-examine transcripts from earlier runs")
      end
    end
  end

  describe "known insights" do
    context "when known_insights are provided" do
      let(:known_insights) do
        [
          instance_double(InsightSuggestion, id: 101, title: "Agent repeatedly fails at rebase step", state: "accepted", effective_proposal_type: "create_job"),
          instance_double(InsightSuggestion, id: 102, title: "Missing memory about test runner config", state: "dismissed", effective_proposal_type: "save_memory")
        ]
      end

      it "includes a Known Insights section" do
        out = described_class.new(repository: repository, known_insights: known_insights).to_s
        expect(out).to include("## Known Insights")
      end

      it "lists each insight id, title, and state" do
        out = described_class.new(repository: repository, known_insights: known_insights).to_s
        expect(out).to include("[101] Agent repeatedly fails at rebase step (accepted, create_job)")
        expect(out).to include("[102] Missing memory about test runner config (dismissed, save_memory)")
      end

      it "instructs the agent not to refile known insights" do
        out = described_class.new(repository: repository, known_insights: known_insights).to_s
        expect(out).to include("Do not refile")
      end

      it "mentions read_insight and list_insights tools for lookup" do
        out = described_class.new(repository: repository, known_insights: known_insights).to_s
        expect(out).to include("read_insight")
        expect(out).to include("list_insights")
      end

      it "lists insights in the order they are provided" do
        out = described_class.new(repository: repository, known_insights: known_insights).to_s
        accepted_pos  = out.index("Agent repeatedly fails at rebase step")
        dismissed_pos = out.index("Missing memory about test runner config")
        expect(accepted_pos).to be < dismissed_pos
      end
    end

    context "when known_insights is empty" do
      it "omits the Known Insights section" do
        out = described_class.new(repository: repository, known_insights: []).to_s
        expect(out).not_to include("Known Insights")
      end
    end
  end

  describe "instructions" do
    it "mentions list_insights and read_insight tools" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("list_insights")
      expect(out).to include("read_insight")
    end

    it "instructs the agent to review stale existing insights and reference target_insight_id" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("revise_existing_insight")
      expect(out).to include("target_insight_id")
      expect(out).to match(/stale, duplicated, or superseded/i)
    end

    it "mentions worker health correlation evidence" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("read_run_worker_health")
      expect(out).to include("CPU starvation")
    end

    it "mentions operational log search guidance and target patterns" do
      out = described_class.new(repository: repository).to_s

      expect(out).to include("read_syrus_logs")
      expect(out).to include("repeated exceptions")
      expect(out).to include("recurring warnings")
      expect(out).to include("retry storms")
      expect(out).to include("queue/worker anomalies")
      expect(out).to include("failed background jobs")
      expect(out).to include("noisy code paths")
    end

    it "requires corroborating log hits before filing an insight" do
      out = described_class.new(repository: repository).to_s

      expect(out).to include("corroborate log hits")
      expect(out).to include("workflow evidence")
      expect(out).to match(/run\s+transcripts/)
      expect(out).to include("multiple occurrences")
      expect(out).to match(/one-off benign log\s+lines/)
    end
  end

  describe "memory dedup guidance" do
    it "instructs the agent to call list_memories before writing a new memory" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("list_memories")
      expect(out).to include("memory already exists for this repository")
    end

    it "instructs stale memories to be proposed for removal instead of deleted directly" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("remove_memory")
      expect(out).to include("target_memory_id")
      expect(out).to include("stale_memory_evidence")
      expect(out).to include("Do NOT call `delete_memory`")
    end
  end

  describe "recent jobs" do
    context "when recent_jobs are provided" do
      it "includes a Recent Jobs section with the job identifier and title" do
        job = Factories.job(user: user, repository: repository)
        job.update!(issue_title: "Fix the thing")
        out = prompt(recent_jobs: [job])
        expect(out).to include("## Recent Completed Jobs")
        expect(out).to include("JOB-#{job.id}")
        expect(out).to include("Fix the thing")
      end

      it "includes workflow and run identifiers when available" do
        job = Factories.job(user: user, repository: repository)
        workflow = job.latest_workflow
        run = workflow.steps.first.runs.first

        out = prompt(recent_jobs: [job])

        expect(out).to include("WF-#{workflow.id} initial")
        expect(out).to include("RUN-#{run.id}")
      end
    end

    context "when recent_jobs is empty" do
      it "omits the Recent Jobs section" do
        out = described_class.new(repository: repository, recent_jobs: []).to_s
        expect(out).not_to include("Recent Jobs")
      end
    end
  end

  describe "memory context" do
    it "is omitted when the user has no repository-scoped memories" do
      output = prompt(user: user)
      expect(output).not_to include("## Memory")
    end
  end
end
