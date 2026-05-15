require "rails_helper"

RSpec.describe Job do
  describe "thread state machine" do
    it "starts open" do
      job = Factories.job
      expect(job).to be_open
    end

    it "transitions open → closed via close!" do
      job = Factories.job
      expect { job.close! }.to change(job, :state).from("open").to("closed")
    end

    it "captures finished_at on close" do
      job = Factories.job
      freeze_time do
        job.close!
        expect(job.finished_at).to eq(Time.current)
      end
    end

    it "stores closure_reason via close_with_reason!" do
      job = Factories.job
      job.close_with_reason!("manual")
      expect(job).to be_closed
      expect(job.closure_reason).to eq("manual")
    end

    it "may_close? is false for an already-closed job" do
      job = Factories.job
      job.close!
      expect(job.may_close?).to be false
    end

    it "may_reopen? is true only for closed jobs" do
      job = Factories.job
      expect(job.may_reopen?).to be false
      job.close!
      expect(job.may_reopen?).to be true
    end

    it "reopen! transitions closed → open and clears closure_reason + finished_at" do
      job = Factories.job
      job.close_with_reason!("cancelled")
      expect(job.closure_reason).to eq("cancelled")
      expect(job.finished_at).to be_present

      job.reopen!
      job.save!

      expect(job.state).to eq("open")
      expect(job.closure_reason).to be_nil
      expect(job.finished_at).to be_nil
    end

    it "reopen does not un-cancel cancelled Runs" do
      job = Factories.job
      run = job.initial_run
      run.start!; run.save!
      job.cancel_active_runs_and_close!("cancelled")
      expect(run.reload.state).to eq("cancelled")

      job.reopen!
      job.save!
      expect(run.reload.state).to eq("cancelled")  # the cancelled invocation
      # really did stop — reopen
      # is about the thread, not
      # the Run
    end
  end

  describe "auto-create initial Run on commit" do
    it "creates exactly one Run with trigger_kind=initial" do
      job = Factories.job
      expect(job.runs.size).to eq(1)
      expect(job.runs.first.trigger_kind).to eq("initial")
    end

    it "defaults the job agent provider from the user's current provider" do
      user = Factories.user(agent_provider: "codex", codex_api_key: "sk-test")
      repository = Factories.repository(user: user)

      job = Factories.job(repository: repository)

      expect(job.agent_provider).to eq("codex")
      expect(job.initial_run.agent_provider).to eq("codex")
    end

    it "defaults the job agent provider from the repository override before the user default" do
      user = Factories.user(agent_provider: "claude", codex_api_key: "sk-test")
      repository = Factories.repository(user: user, agent_provider: "codex")

      job = Factories.job(repository: repository)

      expect(job.agent_provider).to eq("codex")
      expect(job.initial_run.agent_provider).to eq("codex")
    end
  end

  describe "Run helpers" do
    let(:job) { Factories.job }

    it "current_run is the most recent Run" do
      first = job.initial_run
      later = Run.create!(job: job, trigger_kind: "pr_comment")
      expect(job.current_run).to eq(later)
      expect(job.initial_run).to eq(first)
    end

    it "latest_succeeded_run is the most recent succeeded Run" do
      r1 = job.initial_run
      r1.start!; r1.succeed!; r1.save!
      r2 = Run.create!(job: job, trigger_kind: "pr_comment")
      expect(job.latest_succeeded_run).to eq(r1)
      r2.start!; r2.succeed!; r2.save!
      expect(job.latest_succeeded_run).to eq(r2)
    end

    it "any_active_run? reflects queued/running runs" do
      job
      expect(job.any_active_run?).to be true   # initial run starts queued
      job.initial_run.start!
      job.initial_run.save!
      expect(job.any_active_run?).to be true
      job.initial_run.cancel!
      job.initial_run.save!
      expect(job.any_active_run?).to be false
    end
  end

  describe "#retry_with_agent_providers" do
    let(:user) do
      Factories.user(
        claude_oauth_token: "oat-test",
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test"
      )
    end
    let(:repository) { Factories.repository(user: user) }
    let(:job) { Factories.job(repository: repository) }

    def finish_latest_workflow(state:, provider: "claude")
      run = job.initial_run
      run.update!(
        state: state,
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago,
        agent_provider: provider
      )
      job.latest_workflow.update!(
        state: state,
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
    end

    it "returns configured providers excluding the provider from the latest run" do
      finish_latest_workflow(state: "succeeded", provider: "claude")

      expect(job.reload.retry_with_agent_providers).to eq([ "codex" ])
    end

    it "supports failed workflows" do
      finish_latest_workflow(state: "failed", provider: "codex")

      expect(job.reload.retry_with_agent_providers).to eq([ "claude" ])
    end

    it "returns no providers when only one agent is configured" do
      user.update!(codex_api_key: nil)
      finish_latest_workflow(state: "succeeded", provider: "claude")

      expect(job.reload.retry_with_agent_providers).to be_empty
    end

    it "returns no providers when the latest workflow is not failed or succeeded" do
      finish_latest_workflow(state: "cancelled", provider: "claude")

      expect(job.reload.retry_with_agent_providers).to be_empty
    end

    it "uses the job's provider for alternate manual action choices" do
      job.update!(agent_provider: "codex")

      expect(job.alternate_configured_agent_providers).to eq([ "claude" ])
    end
  end

  describe "#record_run_failure!" do
    let(:job) { Factories.job }

    it "increments failure_count" do
      expect { job.record_run_failure! }.to change { job.reload.failure_count }.from(0).to(1)
    end

    it "does not close the job when below the threshold" do
      AppSetting.current.update!(max_job_failures: 3)
      2.times { job.record_run_failure! }
      expect(job.reload).to be_open
    end

    it "closes the job with too_many_failures when threshold is reached" do
      AppSetting.current.update!(max_job_failures: 3)
      3.times { job.record_run_failure! }
      job.reload
      expect(job).to be_closed
      expect(job.closure_reason).to eq("too_many_failures")
    end

    it "is a no-op on job state when job is already closed" do
      job.close_with_reason!("cancelled")
      expect { job.record_run_failure! }.not_to change { job.reload.state }
    end
  end

  describe "#reopen! resets failure_count" do
    it "resets failure_count to 0 on reopen" do
      AppSetting.current.update!(max_job_failures: 3)
      job = Factories.job
      3.times { job.record_run_failure! }
      expect(job.reload).to be_closed

      job.reopen!
      job.save!

      expect(job.reload.failure_count).to eq(0)
      expect(job).to be_open
    end
  end

  describe "scopes" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    describe ".with_pr" do
      it "includes jobs with a pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1, pr_number: 42)
        expect(Job.with_pr).to include(job)
      end

      it "includes jobs with an external_pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1,
                          state: "closed", closure_reason: "preempted",
                          external_pr_number: 7, finished_at: Time.current)
        expect(Job.with_pr).to include(job)
      end

      it "excludes jobs with neither pr_number nor external_pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1)
        expect(Job.with_pr).not_to include(job)
      end
    end

    describe ".without_pr" do
      it "includes jobs with no pr_number and no external_pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1)
        expect(Job.without_pr).to include(job)
      end

      it "excludes jobs with a pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1, pr_number: 42)
        expect(Job.without_pr).not_to include(job)
      end

      it "excludes jobs with an external_pr_number" do
        job = Job.create!(user: user, repository: repository, issue_number: 1,
                          state: "closed", closure_reason: "preempted",
                          external_pr_number: 7, finished_at: Time.current)
        expect(Job.without_pr).not_to include(job)
      end
    end
  end

  describe "direct kind" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "direct? returns true for direct jobs" do
      job = Job.new(kind: "direct")
      expect(job.direct?).to be true
      expect(job.issue?).to be false
      expect(job.cron?).to be false
    end

    it "is valid with no issue_number and no scheduled_task_id" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: nil)
      expect(job).to be_valid
    end

    it "is invalid when issue_number is present" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: 5)
      expect(job).not_to be_valid
      expect(job.errors[:issue_number]).to include("must be blank for direct Jobs")
    end

    it "does NOT auto-spawn an initial Run on create (prompt must be pre-rendered by caller)" do
      job = Job.create!(user: user, repository: repository, kind: "direct")
      expect(job.runs).to be_empty
    end

    it "synthetic_issue returns issue_title/issue_body" do
      job = Job.new(kind: "direct", issue_title: "My task", issue_body: "Do the thing.")
      si = job.synthetic_issue
      expect(si.title).to eq("My task")
      expect(si.body).to eq("Do the thing.")
    end

    it "synthetic_issue handles nil issue_title/issue_body gracefully" do
      job = Job.new(kind: "direct", issue_title: nil, issue_body: nil)
      si = job.synthetic_issue
      expect(si.title).to eq("")
      expect(si.body).to eq("")
    end
  end

  describe "priority" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "defaults to 'medium'" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      expect(job.priority).to eq("medium")
    end

    it "accepts high, medium, and low" do
      %w[high medium low].each do |p|
        job = Job.new(user: user, repository: repository, issue_number: 1, priority: p)
        expect(job).to be_valid, "expected #{p} to be valid"
      end
    end

    it "rejects unknown priority values" do
      job = Job.new(user: user, repository: repository, issue_number: 1, priority: "urgent")
      expect(job).not_to be_valid
      expect(job.errors[:priority]).to be_present
    end

    describe "#solid_queue_priority" do
      it "maps high to a lower integer than medium" do
        high_job = Job.new(priority: "high")
        medium_job = Job.new(priority: "medium")
        expect(high_job.solid_queue_priority).to be < medium_job.solid_queue_priority
      end

      it "maps medium to a lower integer than low" do
        medium_job = Job.new(priority: "medium")
        low_job = Job.new(priority: "low")
        expect(medium_job.solid_queue_priority).to be < low_job.solid_queue_priority
      end
    end
  end

  describe "dependencies" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

    it "seeds parsed dependencies from issue_body when a matching Job exists" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)

      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #42"
      )

      expect(job.dependencies.first.depends_on_job).to eq(prerequisite)
      expect(job.dependencies.first.source).to eq("parsed")
    end

    it "resolves cross-repo parsed dependencies" do
      other_repo = Factories.repository(user: user, owner: "tkadauke", name: "raytracer")
      prerequisite = Job.create!(user: user, repository: other_repo, issue_number: 102)

      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: tkadauke/raytracer#102"
      )

      expect(job.dependencies.first.depends_on_job).to eq(prerequisite)
    end

    it "records pending dependencies when the referenced Job does not exist yet" do
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #999"
      )

      expect(job.dependencies.size).to eq(1)
      pending = job.dependencies.first
      expect(pending).to be_pending
      expect(pending.unresolved_owner).to eq("acme")
      expect(pending.unresolved_repo).to eq("widgets")
      expect(pending.unresolved_number).to eq(999)
      expect(pending.depends_on_job_id).to be_nil
    end

    it "treats pending dependencies as unsatisfied" do
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #999"
      )

      expect(job).not_to be_dependencies_satisfied
      expect(job.unsatisfied_dependencies.size).to eq(1)
      expect(job.unsatisfied_dependencies.first).to be_pending
    end

    it "promotes pending dependencies to resolved when the target Job is later created" do
      dependent = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #42"
      )
      expect(dependent.dependencies.first).to be_pending

      target = Job.create!(user: user, repository: repository, issue_number: 42)

      dependent.reload
      resolved = dependent.dependencies.first
      expect(resolved).to be_resolved
      expect(resolved.depends_on_job).to eq(target)
      expect(resolved.unresolved_owner).to be_nil
    end

    it "promotes pending cross-repo dependencies when the target Job lands" do
      other_repo = Factories.repository(user: user, owner: "tkadauke", name: "raytracer")
      dependent = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: tkadauke/raytracer#102"
      )
      expect(dependent.dependencies.first).to be_pending

      target = Job.create!(user: user, repository: other_repo, issue_number: 102)

      dependent.reload
      expect(dependent.dependencies.first.depends_on_job).to eq(target)
    end

    it "handles reverse-order bulk ingest where later-numbered issues are seen first" do
      # Reproduces the 2026-05-13 bug: GitHub's API often returns issues
      # newest-first. If issue #100 with `Depends-on: #99` is ingested
      # before #99, the parser used to silently drop the dep. With
      # deferred resolution, #100's dep is pending; when #99 lands, the
      # pending row is promoted.
      late = Job.create!(user: user, repository: repository, issue_number: 100,
                         issue_body: "Depends-on: #99")
      expect(late.dependencies.first).to be_pending
      expect(late).not_to be_dependencies_satisfied

      early = Job.create!(user: user, repository: repository, issue_number: 99)

      late.reload
      expect(late.dependencies.first.depends_on_job).to eq(early)
      expect(late).not_to be_dependencies_satisfied  # still unsatisfied because target is open
      early.close_with_reason!("pr_merged")
      expect(late.reload).to be_dependencies_satisfied
    end

    it "is unsatisfied until every dependency has a successful closure reason" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #42")

      expect(job).not_to be_dependencies_satisfied

      prerequisite.close_with_reason!("pr_merged")
      expect(job.reload).to be_dependencies_satisfied
    end
  end

  describe "preempted creation (state: closed at create time)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "does NOT auto-spawn an initial Run when the Job is born closed" do
      preempted = Job.create!(
        user: user, repository: repository, issue_number: 99,
        state: "closed", closure_reason: "preempted",
        external_pr_number: 7, finished_at: Time.current
      )
      expect(preempted.runs).to be_empty
      expect(preempted).to be_closed
      expect(preempted.closure_reason).to eq("preempted")
      expect(preempted.external_pr_number).to eq(7)
    end

    it "auto-spawns a Run for ordinary (open) Job creation" do
      ordinary = Job.create!(user: user, repository: repository, issue_number: 100)
      expect(ordinary.runs.size).to eq(1)
      expect(ordinary.initial_run).to be_present
    end
  end
end
