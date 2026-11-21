require "rails_helper"
require "tmpdir"

RSpec.describe AgentInsights::RunStep do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)

    Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
  end
  let(:workflow) { AgentInsights::Workflow.instantiate(job: job) }
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
        AgentInsights::Suggestion.create!(
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
        AgentInsights::Suggestion.create!(
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
        pending_insight = AgentInsights::Suggestion.create!(
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
          AgentInsights::Suggestion.create!(
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
        pending_insight = AgentInsights::Suggestion.create!(
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
          AgentInsights::Suggestion.create!(
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

    context "recent jobs context" do
      let!(:prior_job) do
        prior = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
        prior.update_columns(
          state: "closed",
          finished_at: Time.utc(2026, 7, 20, 12, 0, 0),
          closure_reason: "agent_insight"
        )
        prior
      end

      it "includes closed direct and cron jobs completed after the analysis window" do
        direct = completed_job(
          kind: "direct",
          issue_number: nil,
          issue_title: "Operator asked for terminal polish",
          completed_at: Time.utc(2026, 7, 22, 9, 0, 0)
        )
        cron = completed_job(
          kind: "cron",
          issue_number: nil,
          scheduled_task_id: scheduled_task.id,
          issue_title: "Scheduled dependency sweep",
          completed_at: Time.utc(2026, 7, 23, 9, 0, 0)
        )

        handler.call

        prompt = run.reload.prompt
        expect(prompt).to include("#{direct.slug} (direct, closed")
        expect(prompt).to include("Operator asked for terminal polish")
        expect(prompt).to include("#{cron.slug} (cron, closed")
        expect(prompt).to include("Scheduled dependency sweep")
      end

      # Regression: the recent-job context preloaded workflows' Steps and Runs
      # with `includes`, which orders both across an IN list of ids that no
      # index can serve. MySQL filesorted whole step and run rows, and every
      # insight run failed with `Out of sort memory`.
      it "builds the recent-job context without sorting whole Step or Run rows" do
        jobs = 3.times.map do |index|
          completed_job(kind: "direct", issue_number: nil, issue_title: "Context job #{index}",
            completed_at: Time.utc(2026, 7, 22, 9, index, 0), step_kind: "grader")
        end

        offenders = wide_row_sort_statements { handler.call }

        expect(offenders).to be_empty
        prompt = run.reload.prompt
        jobs.each do |recent|
          expect(prompt).to include("WF-#{recent.latest_workflow.id}")
          expect(prompt).to include("RUN-#{recent.latest_workflow.steps.first.runs.first.id}")
        end
      end

      # Regression: every job in the window was loaded with its workflows,
      # steps and runs before the 50 most recent were kept, which ran an
      # insight past its compute pod's memory limit and OOM-killed every run on
      # that worker. History is loaded only for the ranked candidates.
      it "loads history only for the most recent candidate jobs" do
        stub_const("AgentInsights::RunStep::RECENT_JOB_LIMIT", 2)
        stub_const("AgentInsights::RunStep::RECENT_JOB_CANDIDATES", 3)
        jobs = 6.times.map do |index|
          completed_job(kind: "direct", issue_number: nil, issue_title: "Window job #{index}",
            completed_at: Time.utc(2026, 7, 22, 9, index, 0))
        end
        loaded_ids = []
        allow(::Workflow).to receive(:where).and_wrap_original do |original, *args, **kwargs|
          loaded_ids.concat(Array(kwargs[:job_id] || args.first.try(:[], :job_id)))
          original.call(*args, **kwargs)
        end

        handler.call

        expect(loaded_ids).to match_array(jobs.last(3).map(&:id))
        prompt = run.reload.prompt
        expect(prompt).to include(jobs[5].slug, jobs[4].slug)
        expect(prompt).not_to include(jobs[0].slug)
      end

      # Regression: every workflow's steps (grader output in `details`) and
      # runs (full prompts) were loaded for each candidate job; a hundred jobs
      # of merge trains ran an insight past its pod's memory limit within a
      # minute. Only the latest workflow is summarised, by step kind and run
      # id/state, so that is all that is loaded.
      it "loads only the latest workflow's step kinds and run states" do
        recent = completed_job(kind: "direct", issue_number: nil, issue_title: "Two attempts",
          completed_at: Time.utc(2026, 7, 22, 9, 0, 0), step_kind: "grader")
        recent.update_columns(state: "queued")
        older = Workflow.create!(job: recent, trigger_kind: "retry")
        older.steps.create!(kind: "grader", position: 0, details: { "output" => "x" * 1000 })
        older.update_columns(state: "failed", created_at: Time.utc(2026, 7, 20), finished_at: Time.utc(2026, 7, 20, 1))
        recent.update_columns(state: "closed")
        recent.reload
        loaded_steps = []
        allow(::Step).to receive(:where).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs).tap { |relation| loaded_steps << kwargs[:workflow_id] if kwargs.key?(:workflow_id) }
        end
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

        begin
          handler.call
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        expect(loaded_steps.flatten).to eq([ recent.latest_workflow.id ])
        history_reads = statements.grep(/FROM ["`](steps|runs)["`] WHERE ["`](steps|runs)["`]\.["`](workflow_id|step_id)["`] (IN|=)/i)
        expect(history_reads).to be_present
        expect(history_reads).to all(satisfy { |sql| !sql.match?(/SELECT ["`](steps|runs)["`]\.\*/i) })
        expect(run.reload.prompt).to include("RUN-#{recent.latest_workflow.steps.first.runs.first.id} grader/succeeded")
      end

      it "includes workflow and run identifiers for evidence lookup" do
        direct = completed_job(
          kind: "direct",
          issue_number: nil,
          issue_title: "Investigate failed handoff",
          completed_at: Time.utc(2026, 7, 22, 9, 0, 0),
          trigger_kind: "coding_handoff",
          step_kind: "grader"
        )
        workflow = direct.latest_workflow
        evidence_run = workflow.steps.first.runs.first

        handler.call

        prompt = run.reload.prompt
        expect(prompt).to include("WF-#{workflow.id} coding_handoff/succeeded")
        expect(prompt).to include("RUN-#{evidence_run.id} grader/succeeded")
      end

      it "does not rely only on issue jobs created during the analysis window" do
        old_issue = completed_job(
          kind: "issue",
          issue_number: 72,
          issue_title: "Old issue with new workflow",
          created_at: Time.utc(2026, 7, 1, 9, 0, 0),
          completed_at: Time.utc(2026, 7, 21, 9, 0, 0)
        )
        direct = completed_job(
          kind: "direct",
          issue_number: nil,
          issue_title: "Fresh direct context",
          completed_at: Time.utc(2026, 7, 22, 9, 0, 0)
        )
        too_old = completed_job(
          kind: "issue",
          issue_number: 73,
          issue_title: "Completed before the insight window",
          created_at: Time.utc(2026, 7, 1, 9, 0, 0),
          completed_at: Time.utc(2026, 7, 19, 9, 0, 0)
        )

        handler.call

        prompt = run.reload.prompt
        expect(prompt).to include("#{old_issue.slug} (issue, closed")
        expect(prompt).to include("#{direct.slug} (direct, closed")
        expect(prompt).not_to include(too_old.slug)
      end
    end
  end

  def scheduled_task
    ScheduledTasks::Task.create!(
      user: user,
      repository: repository,
      name: "Nightly dependency sweep",
      prompt: "Check dependency drift.",
      kind: "cron",
      cron_expression: "0 * * * *"
    )
  end

  def completed_job(kind:, issue_number:, issue_title:, completed_at:, created_at: completed_at, scheduled_task_id: nil, trigger_kind: "initial", step_kind: "implement")
    created = Factories.job_record(
      user: user,
      repository: repository,
      kind: kind,
      issue_number: issue_number,
      issue_title: issue_title,
      scheduled_task_id: scheduled_task_id,
      state: "queued",
      created_at: created_at
    )
    workflow = Workflow.create!(job: created, trigger_kind: trigger_kind)
    step = Step.create!(workflow: workflow, kind: step_kind, position: 0)
    run = Run.create!(job: created, step: step, trigger_kind: trigger_kind)
    run.update_columns(state: "succeeded", finished_at: completed_at)
    step.update_columns(state: "succeeded", finished_at: completed_at)
    workflow.update_columns(state: "succeeded", finished_at: completed_at)
    created.update_columns(state: "closed", finished_at: completed_at, closure_reason: "pr_merged")
    created.reload
  end
end
