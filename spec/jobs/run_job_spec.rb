require "rails_helper"
require "tmpdir"
require "fileutils"

# Integration tests for the Workflow → Step → Run pipeline driven
# through RunJob. The agent_runner is stubbed (no real claude
# subprocess) but everything else runs for real: handlers,
# dispatcher, WorkflowWorkspace, git, push to a local bare repo,
# WebMock-stubbed GitHub PR creation. The bare repo's state is
# the ground truth for "did the agent's work make it to origin?".
RSpec.describe RunJob, :ci_only do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-bare")) }
  let(:user) { Factories.user(name: "Ada Lovelace", github_handle: "ada", email_address: "ada@example.com", github_token: "ghp_test_token", claude_oauth_token: "oat-test") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets",
                         default_branch: "main", trigger_label: "syrus", polling_enabled: true)
  end
  let(:job) do
    Factories.job(
      repository: repository,
      issue_number: 42,
      issue_title: "Add greeting helper",
      issue_body: "We need a greeting helper."
    )
  end

  before(:context) do
    @seed_bare_remote_dir = Pathname.new(Dir.mktmpdir("syrus-bare-seed"))
    seed_remote_with_initial_commit(@seed_bare_remote_dir)
  end

  after(:context) do
    FileUtils.rm_rf(@seed_bare_remote_dir) if @seed_bare_remote_dir
  end

  before do
    AppSetting.current.update!(workflow_admission_control_enabled: true)
    FileUtils.rm_rf(bare_remote_dir)
    cloned = system(
      "git", "clone", "--local", "--bare",
      @seed_bare_remote_dir.to_s, bare_remote_dir.to_s,
      out: File::NULL, err: File::NULL
    )
    raise "failed to clone seed bare remote" unless cloned
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")

    stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 42, title: "Add greeting helper", body: "We need a greeting helper.", state: "open" }.to_json
    )
    stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42/comments").with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: [].to_json
    )
    @pr_stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls").to_return(
      status: 201, headers: { "Content-Type" => "application/json" },
      body: { number: 123, html_url: "https://github.com/acme/widgets/pull/123" }.to_json
    )
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/acme/widgets/pulls(\?.*)?\z}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: [].to_json
    )
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/123").with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 123, state: "open", merged: false, body: "Existing PR body" }.to_json
    )
    @pr_update_stub = stub_request(:patch, "https://api.github.com/repos/acme/widgets/pulls/123").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 123, state: "open", body: "Existing PR body" }.to_json
    )

    RunJob.agent_runner = method(:default_agent_runner)
    stub_no_workflow_judges

    @data_root = Dir.mktmpdir("syrus-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    RunJob.agent_runner = nil
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  describe "stale queue entries" do
    it "discards a missing Run without attempting failure logging" do
      missing_run_id = Run.maximum(:id).to_i + 1

      expect(JobLog).not_to receive(:append!)

      expect { RunJob.perform_now(missing_run_id) }.not_to raise_error
    end

    # Regression: a pool timeout raised before the Run loaded went through
    # handle_failure, which crashed appending a JobLog for the nil Run and
    # buried the timeout under a NoMethodError nothing retried.
    it "re-enqueues a pool timeout raised before the Run loads instead of failing on the nil Run" do
      run = job.initial_run
      allow(AppSetting).to receive(:runs_paused?)
        .and_raise(ActiveRecord::ConnectionTimeoutError, "all pooled connections were in use")

      expect(JobLog).not_to receive(:append!)
      expect_any_instance_of(RunJob).to receive(:retry_job).with(hash_including(:wait))
      expect { RunJob.perform_now(run.id) }.not_to raise_error
      expect(run.reload).to be_queued
    end
  end

  describe "execution acquisition" do
    it "retries a transient lifecycle lock timeout" do
      run = job.initial_run
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      attempts = 0

      # Acquisition locks the Run's ancestry with Lineage.lock! (NY40).
      # Counts the Run's: starting its Workflow and Step locks their own too.
      allow(Lineage).to receive(:lock!).and_wrap_original do |original, *args, &block|
        if args.first.is_a?(Run)
          attempts += 1
          raise ActiveRecord::LockWaitTimeout, "lock wait timeout" if attempts == 1
        end

        original.call(*args, &block)
      end

      expect(run_job.send(:acquire_run_execution!)).to be(true)
      # The failed claim, its retry, and the start event's Lineage.lock! inside it.
      expect(attempts).to eq(3)
      expect(run.reload).to be_running
      expect(run.step.reload).to be_running
      expect(run.workflow.reload).to be_running
    end

    # Regression: sibling graders failing together queued on the Job row,
    # and the last of the burst timed out failing its Run.
    it "retries a lock wait while failing the Run instead of losing the failure" do
      run = job.initial_run
      run.update!(state: "running", started_at: Time.current)
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      attempts = 0
      allow(run).to receive(:fail!).and_wrap_original do |original, *args, **kwargs, &block|
        attempts += 1
        raise ActiveRecord::LockWaitTimeout, "lock wait timeout" if attempts == 1

        original.call(*args, **kwargs, &block)
      end
      allow(run).to receive(:reload).and_return(run)

      run_job.send(:handle_failure, Steps::Base::StepFailed.new("grader rspec failed (exit 1)"))

      expect(run.reload.state).to eq("failed")
      expect(attempts).to be >= 2
    end

    # Regression: an auto-merge Run persisted its own failure successfully,
    # then lost the landing-state update to a MySQL deadlock. That secondary
    # write needs the same bounded retry as the surrounding lifecycle writes.
    it "retries a deadlock while recording an auto-merge landing failure" do
      landing_job = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 43,
        pr_number: 124,
        state: "implemented"
      )
      landing_job.approve!(via: "github_review")
      landing_job.start_landing!
      landing_job.save!
      workflow = Workflows::AutoMerge.instantiate(job: landing_job)
      run = workflow.steps.last.runs.create!(
        job: landing_job,
        trigger_kind: "auto_merge",
        agent_provider: workflow.agent_provider,
        state: "running",
        started_at: Time.current
      )
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, workflow)
      run_job.instance_variable_set(:@job, landing_job)
      attempts = 0
      allow(LandingFailureHandler).to receive(:call).and_wrap_original do |original, **kwargs|
        attempts += 1
        raise ActiveRecord::Deadlocked, "deadlock found" if attempts == 1

        original.call(**kwargs)
      end

      run_job.send(:handle_failure, Steps::Base::StepFailed.new("required grader failed"))

      expect(attempts).to eq(2)
      expect(landing_job.reload).to be_implemented
      expect(landing_job.landing_failure_reason).to include("required grader failed")
    end

    it "records recovered lock contention with queue and lifecycle context" do
      run = job.initial_run
      run_job = RunJob.new
      run_job.queue_name = "merges"
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      attempts = 0
      messages = []
      allow(Rails.logger).to receive(:warn) { |message| messages << JSON.parse(message) }
      # Acquisition locks the Run's ancestry with Lineage.lock! (NY40).
      allow(Lineage).to receive(:lock!).and_wrap_original do |original, *args, &block|
        attempts += 1
        raise ActiveRecord::LockWaitTimeout, "lock wait timeout" if attempts == 1

        original.call(*args, &block)
      end

      expect(run_job.send(:acquire_run_execution!)).to be(true)
      expect(messages).to include(a_hash_including(
        "event" => "run_lifecycle_persistence_contention",
        "queue" => "merges",
        "job_id" => job.id,
        "workflow_id" => run.workflow_id,
        "run_id" => run.id,
        "attempt" => 1,
        "exhausted" => false
      ))
      samples = Syrus::Metrics.counter(:syrus_run_lifecycle_lock_retries_total).samples.to_h
      expect(samples.fetch(kind: "acquire_execution", queue: "merges", outcome: "recovered")).to eq(1)
    end

    it "records exhausted lifecycle contention before deferring the still-queued run" do
      run = job.initial_run
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      messages = []
      allow(Rails.logger).to receive(:warn) { |message| messages << JSON.parse(message) }
      allow(Lineage).to receive(:lock!).and_raise(ActiveRecord::LockWaitTimeout, "still locked")

      allow(run_job).to receive(:defer_run)
      expect(run_job.send(:acquire_run_execution!)).to be(false)
      expect(run_job).to have_received(:defer_run).with(run.id, anything)
      expect(messages.last).to include(
        "event" => "run_lifecycle_persistence_contention",
        "job_id" => job.id,
        "workflow_id" => run.workflow_id,
        "run_id" => run.id,
        "attempt" => RunJob::LIFECYCLE_LOCK_RETRY_ATTEMPTS,
        "exhausted" => true,
        "error_class" => "ActiveRecord::LockWaitTimeout",
        "error_message" => "still locked"
      )
      expect(messages.last.fetch("error_backtrace")).to be_an(Array)
    end

    # A grader fan-out claims a few dozen Runs of one Workflow at once; the
    # losers of the ancestry row locks used to fail before running anything.
    it "defers a queued run instead of failing it when claiming it stays lock-contended" do
      run = job.initial_run
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      allow(Lineage).to receive(:lock!).and_raise(ActiveRecord::LockWaitTimeout, "still locked")

      expect(run_job).to receive(:defer_run).with(run.id, be_between(RunJob::ACQUIRE_CONTENTION_RETRY_DELAY, RunJob::ACQUIRE_CONTENTION_RETRY_DELAY * 2))

      expect(run_job.send(:acquire_run_execution!)).to be(false)
      expect(run.reload).to be_queued
      expect(run.step.reload).to be_queued
    end

    it "defers a queued run when another work unit owns its required lock" do
      run = job.initial_run
      run_job = RunJob.new
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, run.step)
      run_job.instance_variable_set(:@workflow, run.workflow)
      run_job.instance_variable_set(:@job, job)
      owner = WorkUnit.new(id: 123)
      conflict = WorkUnits::Launcher::LockConflict.new(
        lock_key: "landing:repository:#{repository.id}",
        work_unit: owner
      )
      allow_any_instance_of(WorkUnit).to receive(:mark_running!).and_raise(conflict)

      expect(run_job).to receive(:defer_run).with(run.id, RunJob::WORK_UNIT_LOCK_RETRY_DELAY)

      expect(run_job.send(:acquire_run_execution!)).to be(false)
      expect(run.reload).to be_queued
      expect(run.step.reload).to be_queued
      expect(run.workflow.reload).to be_queued
    end
  end

  describe "stale retry workflows" do
    it "cancels a retry run if the job was approved before it started" do
      initial_run = job.initial_run
      initial_run.start!
      initial_run.succeed!
      initial_run.save!

      retry_workflow = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
      retry_step = retry_workflow.first_step
      retry_run = retry_step.runs.create!(
        job: job,
        trigger_kind: "retry",
        agent_provider: job.agent_provider
      )
      job.update_columns(state: "approved", updated_at: Time.current)

      RunJob.perform_now(retry_run.id)

      expect(retry_workflow.reload).to be_cancelled
      expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("approved")
      expect(retry_run.reload).to be_cancelled
    end

    it "enqueues Job-state reconciliation after cancelling a retry for a ready PR" do
      initial_run = job.initial_run
      initial_run.start!
      initial_run.succeed!
      initial_run.save!

      retry_workflow = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
      retry_step = retry_workflow.first_step
      retry_run = retry_step.runs.create!(
        job: job,
        trigger_kind: "retry",
        agent_provider: job.agent_provider
      )
      job.update_columns(
        state: "queued",
        pr_number: 2174,
        branch_name: "syrus/direct-15",
        commits_behind_base: 0,
        pr_checks_state: "passing",
        updated_at: Time.current
      )

      expect {
        RunJob.perform_now(retry_run.id)
      }.to have_enqueued_job(ReconcileJobStatesJob)

      expect(retry_workflow.reload).to be_cancelled
      expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("pr_ready")
      expect(retry_run.reload).to be_cancelled
    end
  end

  # ----- Initial workflow ----------------------------------------

  describe "Initial workflow (issue → PR)" do
    it "releases a checkpointed provider without advancing or failing the background Job" do
      RunJob.agent_runner = ->(**_) {
        current_run = Thread.current[:syrus_current_run]
        if current_run.step.kind == "implement"
          request = ChatPendingAction.create!(
            request_kind: "authorization_request", user: user, repository: repository,
            origin: current_run, subject: user, runtime_role: "implementer",
            deduplication_key: "workflow-run-authorization",
            purpose: "Request a protected operation"
          )
          request.checkpoint_authorization!(payload: { run_id: current_run.id })
          AgentInvocation::Result.new(
            turns: 1, exit_status: nil, timed_out: false, is_error: false,
            outcome: "stopped", final_text: nil, session_id: "authorization-session",
            stopped: true
          )
        else
          default_agent_runner(**_)
        end
      }

      job
      drain_workflow!(job)

      workflow = job.workflows.first
      implement = workflow.steps.find_by!(kind: "implement")
      expect(implement.reload).to be_running
      expect(implement.runs.first.reload).to be_running
      expect(workflow.reload).to be_running
      expect(job.reload).to be_running
      expect(job).to be_waiting_for_permission
      expect(implement.runs.first.job_logs.pluck(:chunk).join).to include("released its provider while waiting for permission")
    end

    # A workspace repair (or reaper, or operator stop) can end the Run while
    # implement is still preparing. Launching the agent afterwards only failed
    # against an already-closed invocation context and overwrote the real
    # outcome with "agent reported error".
    it "stops before launching the agent when the Run was ended externally during preparation" do
      launched_kinds = []
      RunJob.agent_runner = ->(**kwargs) {
        launched_kinds << Thread.current[:syrus_current_run].step.kind
        default_agent_runner(**kwargs)
      }
      allow_any_instance_of(Steps::Implement).to receive(:run_agent).and_wrap_original do |original, *args, **kwargs|
        current = original.receiver.run
        Run.where(id: current.id).update_all(state: "failed", finished_at: Time.current, agent_outcome: "workspace_recovery_failed")
        original.call(*args, **kwargs)
      end

      job
      drain_workflow!(job)

      implement = job.workflows.first.steps.find_by!(kind: "implement")
      run = implement.runs.first.reload
      expect(launched_kinds).not_to include("implement")
      expect(run).to have_attributes(state: "failed", agent_outcome: "workspace_recovery_failed")
      expect(run.job_logs.pluck(:chunk).join).to include("stopped: run ##{run.id} is failed; stopping before launching the agent")
    end

    it "runs implement → summarize → pr_open end-to-end, opens PR, and records commit metadata" do
      expect(PollRebaseJob).to receive(:set).with(hash_including(:wait)).and_return(double(perform_later: true))

      job
      drain_workflow!(job)

      job.reload
      wf = job.workflows.first
      expect(wf.trigger_kind).to eq("initial")
      expect(wf.state).to eq("succeeded")
      expect(wf.steps.pluck(:kind, :state)).to eq([
        [ "prepare",          "succeeded" ],
        [ "implement",        "succeeded" ],
        [ "dependency_audit", "succeeded" ],
        [ "summarize",        "succeeded" ],
        [ "test_plan",        "succeeded" ],
        [ "pr_open",          "succeeded" ]
      ])
      expect(wf.artifact("pr_title")).to eq("Add greeting helper")
      expect(job.pr_number).to eq(123)
      expect(job.branch_name).to eq("syrus/issue-42-#{job.id}")
      expect(@pr_stub).to have_been_requested
      expect(job.issue_title).to eq("Add greeting helper")
      expect(job.issue_body).to eq("We need a greeting helper.")

      branches = `git --git-dir=#{bare_remote_dir} branch --list 'syrus/*'`.split("\n").map(&:strip)
      expect(branches).to include(job.branch_name)

      tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{job.branch_name}`.strip
      expect(tip).to eq("Add greeting helper")

      body = `git --git-dir=#{bare_remote_dir} log -1 --format='%b' #{job.branch_name}`.strip
      expect(body).to include("Adds a tiny greet helper used by the welcome page.")

      full = `git --git-dir=#{bare_remote_dir} log -1 --format='%B' #{job.branch_name}`.strip
      expect(full).to include("Closes #42")
      expect(full).not_to include("Co-Authored-By:")

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip
      expect(author).to eq("Ada Lovelace <ada@example.com>")

      expect(WorkflowWorkspace.path_for(wf)).not_to exist
    end

    it "authors commits as the owner's own PAT identity even when the App is registered and installed" do
      AppSetting.current.update!(github_app_id: 12_345, github_app_slug: "tkadauke-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      allow_any_instance_of(Installation).to receive(:fresh_token).and_return("ghs_installation")

      job; drain_workflow!(job)

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip

      expect(author).to eq("Ada Lovelace <ada@example.com>")
      expect(
        a_request(:post, "https://api.github.com/repos/acme/widgets/pulls")
          .with(headers: { "Authorization" => "token ghp_test_token" })
      ).to have_been_made
    end

    it "authors commits as the App bot when the App is registered and installed and the owner has no PAT" do
      AppSetting.current.update!(github_app_id: 12_345, github_app_slug: "tkadauke-syrus")
      user.update!(github_token: nil)
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      allow_any_instance_of(Installation).to receive(:fresh_token).and_return("ghs_installation")

      job; drain_workflow!(job)

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip

      expect(author).to eq("tkadauke-syrus[bot] <tkadauke-syrus[bot]@users.noreply.github.com>")
      expect(
        a_request(:post, "https://api.github.com/repos/acme/widgets/pulls")
          .with(headers: { "Authorization" => "token ghs_installation" })
      ).to have_been_made
    end

    it "workspace stays on disk when the Workflow fails (retry-from-failed-step needs it)" do
      # A failure that is not transient, so the Workflow fails outright; a
      # transient provider error now waits out a backoff before its rerun.
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)
      wf = job.workflows.last
      expect(wf.state).to eq("failed")
      expect(WorkflowWorkspace.path_for(wf)).to exist
      expect(wf.cleaned_up_at).to be_nil
    end

    it "workspace is torn down when a Run is cancelled (cascade to Workflow)" do
      job
      wf = job.workflows.last
      step = wf.first_step
      run = step.runs.first

      # Seed a workspace directory so cleanup has something real to remove.
      wf_path = WorkflowWorkspace.path_for(wf)
      FileUtils.mkdir_p(wf_path.to_s)
      expect(wf_path).to exist

      run.update!(state: "running", started_at: 1.minute.ago)
      run.cancel!
      run.save!

      expect(wf.reload.state).to eq("cancelled")
      expect(wf_path).not_to exist
    end

    it "adds human trigger attribution to direct PR descriptions" do
      direct = user.jobs.create!(
        repository: repository,
        kind: "direct",
        issue_title: "Manual tidy",
        issue_body: "Clean up the docs."
      )
      workflow = Workflows::Initial.instantiate(job: direct, agent_provider: direct.agent_provider)
      StepDispatcher.start_workflow(workflow, prompt: Prompts::DirectJob.new(prompt: direct.issue_body).to_s)

      drain_workflow!(direct)

      expect(a_request(:post, "https://api.github.com/repos/acme/widgets/pulls").with(
        body: hash_including("body" => including("Triggered by @ada"))
      )).to have_been_made
    end
  end

  # ----- PrFeedback workflow -------------------------------------

  describe "PrFeedback workflow (pr_comment → respond → grade → summarize_amend → try(push))" do
    let(:job) { implemented_job_with_branch }

    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job)
        .and_return(RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "no .syrus.yml", criteria: []))
      WebMock.reset_executed_requests!
    end

    it "runs the chain on the existing branch and pushes a follow-up commit" do
      wf = Workflows::PrFeedback.instantiate(
        job: job,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "tighten the docstring", "created_at" => Time.current.iso8601 } ] }
      )
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)
      wf.reload

      expect(wf.state).to eq("succeeded")
      kinds_and_states = wf.steps.where.not(kind: "grader").pluck(:kind, :state)
      expect(kinds_and_states).to eq([
        [ "prepare",              "succeeded" ],
        [ "respond",              "succeeded" ],
        [ "dependency_audit",           "succeeded" ],
        [ "dependency_audit_pr_comment", "succeeded" ],
        [ "summarize_amend",      "succeeded" ],
        [ "refresh_job_metadata", "succeeded" ],
        [ "push",                 "succeeded" ]
      ])
      # No new PR — same Job's existing one
      expect(@pr_stub).not_to have_been_requested
      # Branch on origin should now have one extra commit
      log = `git --git-dir=#{bare_remote_dir} log --oneline #{job.branch_name}`.split("\n")
      expect(log.size).to be >= 2
    end
  end

  # ----- Retry workflow ------------------------------------------

  describe "Retry workflow (retry → implement → grade → summarize → test_plan → pr_open)" do
    let(:job) { retriable_job_with_branch }

    before do
      WebMock.reset_executed_requests!
    end
  end

  # ----- Rebase workflow -----------------------------------------

  describe "Rebase workflow" do
    before do
      job; drain_workflow!(job)
      WebMock.reset_executed_requests!
      allow_any_instance_of(GithubClient).to receive(:pull_request)
        .and_return(Struct.new(:merged).new(false))
    end

    it "auto_rebase clean → skips agent_rebase, force_pushes, and succeeds" do
      # The deterministic AutoRebase service will succeed cleanly
      # since the branch tip is already up to date with main.
      wf = Workflows::Rebase.instantiate(job: job)
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)
      wf.reload

      expect(wf.state).to eq("succeeded")
      kinds_states = wf.steps.pluck(:kind, :state)
      expect(kinds_states[0]).to eq([ "auto_rebase",  "succeeded" ])
      expect(kinds_states[1]).to eq([ "agent_rebase", "skipped" ])
      expect(kinds_states[2]).to eq([ "force_push",   "succeeded" ])
    end
  end

  # ----- Cron Job (scheduled task) -------------------------------

  describe "Cron Job (scheduled task fire)" do
    let(:scheduled_task) do
      ScheduledTasks::Task.create!(
        user: user, repository: repository,
        name: "Sweep dead code", prompt: "Look for dead code.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
    end

    it "runs implement → summarize → pr_open with a pre-rendered prompt and opens a PR" do
      result = ScheduledTasks::Fire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      job.reload

      wf = job.workflows.last
      expect(wf.state).to eq("succeeded")
      expect(job.pr_number).to eq(123)
      expect(job.branch_name).to start_with("syrus/scheduled-#{scheduled_task.id}-")
    end

    it "does not add a Co-Authored-By trailer for cron jobs" do
      result = ScheduledTasks::Fire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      full = `git --git-dir=#{bare_remote_dir} log -1 --format='%B' #{job.branch_name}`.strip

      expect(full).not_to include("Co-Authored-By:")
    end

    it "no-changes path: agent surveys, finds nothing → Run fails (implement step), Workflow fails, Job closes no_changes" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        # Don't write anything — no diff.
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      result = ScheduledTasks::Fire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      job.reload

      wf = job.workflows.last
      expect(wf.state).to eq("failed")
      implement_run = wf.steps.find_by(kind: "implement").runs.first
      expect(implement_run.state).to eq("failed")
      expect(job.state).to eq("closed")
      expect(job.closure_reason).to eq("no_changes")
    end
  end

  # ----- Failure paths -------------------------------------------

  describe "implement step: agent reported semantic error" do
    it "Run + Step + Workflow all marked failed; failure_count incremented; no PR opened" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 50, exit_status: 0, timed_out: false,
                                    is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      wf = job.workflows.last
      expect(wf.state).to eq("failed")
      expect(wf.failure_count).to eq(1)
      implement = wf.steps.find_by(kind: "implement")
      expect(implement.state).to eq("failed")
      expect(implement.runs.first.agent_outcome).to eq("error_max_turns")
      expect(@pr_stub).not_to have_been_requested
    end
  end

  describe "implement step: agent produced no changes" do
    it "Run + Step + Workflow fail; Job closes no_changes; no PR opened" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      expect(job.workflows.last.state).to eq("failed")
      expect(job.reload.state).to eq("closed")
      expect(job.closure_reason).to eq("no_changes")
      expect(@pr_stub).not_to have_been_requested
    end
  end

  describe "implement step: agent broke git state (orphan branch)" do
    it "raises AgentBrokeGitState, stamps git_state_corrupt outcome" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        sh("git -C #{workspace_path} checkout --orphan oprhan-branch")
        File.write(File.join(workspace_path, "newfile.rb"), "puts 'hi'\n")
        AgentInvocation::Result.new(turns: 5, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      run = job.workflows.last.steps.find_by(kind: "implement").runs.first
      expect(run.state).to eq("failed")
      expect(run.agent_outcome).to eq("git_state_corrupt")
    end
  end

  describe "handle_failure resilience to dirty in-memory state" do
    # Reproduces the Job 360 wedge: Steps::Respond raised
    # ActiveRecord::ValueTooLong on `run.update!(prompt: ...)` because
    # the new context-rich prompt exceeded the TEXT column cap. The
    # rescue in #perform reached handle_failure, but the still-dirty
    # giant prompt was attached to @run. The naive @run.save! inside
    # handle_failure re-raised ValueTooLong, the Run never transitioned
    # to :failed, and Step/Workflow/Job stayed wedged at :running with
    # no cascade. handle_failure now reloads @run before fail!/save!
    # so the dirty in-memory attribute is discarded and the failure
    # transition can proceed.
    # Emulates the column-overflow path on SQLite (no TEXT limit
    # there): mark the prompt dirty in-memory with a giant value
    # right before the step raises, then make Run#save! raise
    # ValueTooLong whenever the dirty prompt is > the simulated
    # column cap. The pre-fix code path called fail! → save!
    # without reload, so the dirty prompt re-triggered the
    # overflow and the Run never transitioned. With reload, the
    # dirty attribute is discarded; save! succeeds.
    it "still transitions Run → :failed when the action left a too-long unsaved attribute on the Run" do
      RunJob.agent_runner = ->(**_) {
        # Dirty the EXACT in-memory Run instance that RunJob's
        # handle_failure will operate on. Thread.current's
        # :syrus_current_run is set by perform; assign_attributes
        # leaves the giant prompt unsaved on that instance,
        # exactly mirroring what Steps::Respond did via update!
        # before MySQL raised. SQLite has no TEXT cap, so we
        # simulate the overflow via the save! stub below.
        Thread.current[:syrus_current_run].assign_attributes(prompt: "X" * 200_000)
        raise StandardError, "simulated mid-step failure"
      }

      # Materialize the Job + initial chain before installing the
      # save! stub (the factory's chain bootstrap calls save! too,
      # and we don't want to fail those).
      job

      # Any Run.save! whose in-memory prompt is over 100 KB raises
      # ValueTooLong, like MySQL would on the real TEXT column. The
      # fix's reload discards the dirty attr inside handle_failure,
      # so the post-reload save! sees the persisted (short) prompt
      # and proceeds.
      # Any Run save (save or save!) whose in-memory prompt is over
      # 100 KB raises ValueTooLong, like MySQL would on the real
      # TEXT column. AASM's event! uses save (not save!), so we
      # have to intercept both to simulate the overflow correctly.
      # The fix's reload discards the dirty attr inside
      # handle_failure, so the post-reload AASM save sees the
      # persisted (short) prompt and proceeds.
      simulated_cap = 100_000
      simulate_overflow_save = lambda do |original, *args, **kwargs|
        instance = original.receiver
        if instance.prompt.to_s.bytesize > simulated_cap
          raise ActiveRecord::ValueTooLong,
                "Mysql2::Error: Data too long for column 'prompt' at row 1"
        end
        original.call(*args, **kwargs)
      end
      allow_any_instance_of(Run).to receive(:save!).and_wrap_original(&simulate_overflow_save)
      allow_any_instance_of(Run).to receive(:save).and_wrap_original(&simulate_overflow_save)

      drain_workflow!(job)

      run = job.workflows.last.steps.find_by(kind: "implement").runs.first
      expect(run.state).to eq("failed")
      expect(run.job.reload.state).to eq("failed")
    end
  end

  describe "RunDiagnostic capture on step failure" do
    it "snapshots exception + repo metadata when a Run fails" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: true,
                                    outcome: "error_during_execution", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      run = job.workflows.last.steps.find_by(kind: "implement").runs.first
      diag = run.run_diagnostic
      expect(diag).to be_present
      expect(diag.error_class).to match(/AgentRunFailed|StepFailed/)
      expect(diag.repo_snapshot["run_trigger_kind"]).to eq("initial")
    end
  end

  describe "two failure handlers racing on one Run" do
    # Handler B loads the Run while it is still running and starts capturing;
    # handler A runs its whole failure path (capture + fail! + cascade) inside
    # B's capture, i.e. after B read the Run but before B wrote anything. B
    # then goes through the real create_or_find_by! (hitting the unique
    # run_id index), fail! on its stale Run, and the workflow bookkeeping.
    # Deterministic interleaving, no threads. Runs on the test database
    # (SQLite locally); the unique index and the code path are the same ones
    # MySQL exercises in production.
    def build_handler(run_id)
      handler = RunJob.new
      run = Run.find(run_id)
      handler.instance_variable_set(:@run, run)
      handler.instance_variable_set(:@step, run.step)
      handler.instance_variable_set(:@workflow, run.step.workflow)
      handler.instance_variable_set(:@job, run.job)
      handler
    end

    it "persists one diagnostic, keeps the first failure and reaches consistent terminal states" do
      job
      run = Run.where(job_id: job.id).order(:id).first
      run.update_columns(state: "running", started_at: Time.current)
      run.step.update_columns(state: "running")
      run.step.workflow.update_columns(state: "running")

      handler_a = build_handler(run.id)
      handler_b = build_handler(run.id)
      first_error = StandardError.new("first failure")
      second_error = StandardError.new("second failure")

      original_capture = CaptureRunDiagnostic.method(:capture)
      raced = false
      allow(CaptureRunDiagnostic).to receive(:capture) do |captured_run, exception, **kwargs|
        if !raced && exception.equal?(second_error)
          raced = true
          handler_a.send(:handle_failure, first_error)
        end
        original_capture.call(captured_run, exception, **kwargs)
      end

      expect { handler_b.send(:handle_failure, second_error) }.not_to raise_error

      expect(raced).to be(true)
      expect(RunDiagnostic.where(run_id: run.id).count).to eq(1)
      expect(RunDiagnostic.find_by(run_id: run.id).error_message).to eq("first failure")
      expect(run.reload.state).to eq("failed")
      expect(run.step.reload.state).to eq("failed")
      expect(run.step.workflow.reload.state).to eq("failed")
    end

    it "does not let a leftover unsaved diagnostic on the Run's has_one re-insert during fail!" do
      job
      run = Run.where(job_id: job.id).order(:id).first
      run.update_columns(state: "running", started_at: Time.current)
      run.step.update_columns(state: "running")
      run.step.workflow.update_columns(state: "running")
      handler = build_handler(run.id)

      # The writer that produced this state before CaptureRunDiagnostic stopped
      # assigning `run:` (the run is autosaved through Run has_one
      # :run_diagnostic by fail!/save!). The guard in handle_failure must
      # recover instead of letting RecordNotUnique escape.
      allow(CaptureRunDiagnostic).to receive(:capture) do |captured_run, *_|
        RunDiagnostic.create!(run_id: captured_run.id, error_class: "StandardError", error_message: "original failure")
        captured_run.association(:run_diagnostic).target =
          RunDiagnostic.new(run: captured_run, error_class: "Duplicate", error_message: "dup")
      end

      expect { handler.send(:handle_failure, StandardError.new("original failure")) }.not_to raise_error

      expect(RunDiagnostic.where(run_id: run.id).count).to eq(1)
      expect(RunDiagnostic.find_by(run_id: run.id).error_message).to eq("original failure")
      expect(run.reload.state).to eq("failed")
      expect(run.step.reload.state).to eq("failed")
      expect(run.step.workflow.reload.state).to eq("failed")
    end
  end

  describe "AutoMerge workflow" do
    it "reconciles a successful auto_merge when a poller cancels the active run before RunJob records success" do
      repository.update!(auto_merge_enabled: true)
      landing_job = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 42,
        pr_number: 17,
        branch_name: "syrus/issue-42-landing",
        state: "landing"
      )
      workflow = Workflow.create!(
        job: landing_job,
        user: user,
        trigger_kind: "auto_merge",
        agent_provider: landing_job.agent_provider
      )
      step = Step.create!(workflow: workflow, kind: "auto_merge", position: 0)
      run = Run.create!(
        job: landing_job,
        step: step,
        trigger_kind: "auto_merge",
        agent_provider: landing_job.agent_provider
      )
      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/17").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 17,
          state: "open",
          merged: false,
          body: "Existing PR body",
          head: { sha: "head-sha" },
          base: { ref: "main", sha: "base-sha" }
        }.to_json
      )

      allow_any_instance_of(Steps::AutoMerge).to receive(:call) do |handler|
        handler.job.close_with_reason!("pr_merged")
        handler.run.cancel!
        handler.run.save!
      end

      RunJob.perform_now(run.id)

      expect(run.reload).to be_succeeded
      expect(step.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(landing_job.reload).to be_closed
      expect(landing_job.closure_reason).to eq("pr_merged")
      expect(run.job_logs.pluck(:chunk).join("\n")).to include(
        "handler auto_merge returned successfully, but terminal state was observed"
      )
      expect(StateTransition.where(subject: run, from_state: "cancelled", to_state: "succeeded", source: "reconciler")).to exist
    end

    it "reconciles a landed merge_train_land even when the workflow has a cancellation artifact" do
      repository.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      landing_job = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 42,
        pr_number: 17,
        branch_name: "syrus/issue-42-landing",
        state: "landing"
      )
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "main", state: "landing")
      MergeTrainMember.create!(merge_train: train, job: landing_job, position: 0)
      workflow = Workflow.create!(
        job: landing_job,
        user: user,
        trigger_kind: "merge_train",
        agent_provider: landing_job.agent_provider,
        artifacts: { "merge_train_id" => train.id }
      )
      step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 0)
      run = Run.create!(
        job: landing_job,
        step: step,
        trigger_kind: "merge_train",
        agent_provider: landing_job.agent_provider
      )
      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/17").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 17,
          state: "open",
          merged: false,
          body: "Member PR body",
          head: { sha: "member-head-sha" },
          base: { ref: "main", sha: "base-sha" }
        }.to_json
      )
      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/3095").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 3095,
          state: "closed",
          merged: true,
          body: "Syrus integration PR",
          head: { sha: "integration-head-sha" },
          base: { ref: "main", sha: "base-sha" }
        }.to_json
      )

      allow_any_instance_of(Steps::MergeTrainLand).to receive(:call) do |handler|
        handler.workflow.set_artifact!(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT, 3095)
        handler.workflow.update!(
          artifacts: handler.workflow.artifacts.merge(
            "cancelled_reason" => "operator_cancelled",
            "cancelled_at" => Time.current.iso8601
          )
        )
        handler.workflow.cancel!
        handler.workflow.save!
      end

      RunJob.perform_now(run.id)

      expect(run.reload).to be_succeeded
      expect(step.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(workflow.artifact(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT)).to eq(3095)
      expect(run.job_logs.pluck(:chunk).join("\n")).to include(
        "handler merge_train_land returned successfully, but terminal state was observed",
        "run reconciled after terminal success race: merge_train_land: integration PR #3095 already merged on GitHub"
      )
      expect(StateTransition.where(subject: workflow, from_state: "cancelled", to_state: "succeeded", source: "reconciler")).to exist
    end

    it "runs final graders before repairing, pushing, and merging" do
      AppSetting.current.update!(grade_max_iterations: 2)
      repository.update!(auto_merge_enabled: true)
      commit_file_to_remote(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: test -f grade-pass
      YAML
      branch_name = "syrus/issue-42-landing"
      create_branch_to_remote(branch_name, "feature.rb" => "def greet = 'hello'\n")

      landing_job = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 42,
        pr_number: 17,
        branch_name: branch_name,
        state: "implemented"
      )
      landing_job.approve!(via: "operator", by_user: user)
      landing_job.save!
      landing_job.start_landing!
      landing_job.save!

      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/17").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 17,
          state: "open",
          mergeable: true,
          mergeable_state: "clean",
          body: "Existing PR body",
          labels: [],
          head: { sha: "head-sha" },
          base: { ref: "main", sha: "base-sha" }
        }.to_json
      )
      stub_request(:patch, "https://api.github.com/repos/acme/widgets/pulls/17").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { number: 17, state: "open", body: "Existing PR body" }.to_json
      )
      stub_request(:get, "https://api.github.com/repos/acme/widgets/git/refs/heads/main").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: { sha: "base-sha" } }.to_json
      )
      stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/17/reviews")
        .with(query: hash_including({}))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { state: "APPROVED", commit_id: "head-sha" } ].to_json
        )
      merge_stub = stub_request(:put, "https://api.github.com/repos/acme/widgets/pulls/17/merge").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { merged: true }.to_json
      )
      comment_stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/issues/17/comments").to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { id: 1 }.to_json
      )
      stub_request(:delete, "https://api.github.com/repos/acme/widgets/git/refs/heads/#{branch_name}").to_return(
        status: 204, body: ""
      )

      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        File.write(File.join(workspace_path, "grade-pass"), "ok\n") if current.step.kind == "landing_fix" && current.iteration >= 2
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "landing-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }

      workflow = Workflows::AutoMerge.instantiate(job: landing_job)
      StepDispatcher.start_workflow(workflow)
      drain_workflow!(landing_job)

      expect(workflow.reload).to be_succeeded
      expect(workflow.steps.where(kind: "landing_fix").order(:iteration).pluck(:iteration)).to eq([ 2 ])
      expect(workflow.steps.where(kind: "grader_collect").order(:iteration).pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "succeeded" ]
      ])
      expect(landing_job.reload).to be_closed
      expect(landing_job.closure_reason).to eq("pr_merged")
      expect(merge_stub).to have_been_requested
      expect(comment_stub).to have_been_requested
      expect(`git --git-dir=#{bare_remote_dir} show #{landing_job.branch_name}:grade-pass`).to eq("ok\n")
    end
  end

  describe "log resilience to blank chunks" do
    it "skips persisting empty chunks but bumps the heartbeat" do
      RunJob.agent_runner = ->(workspace_path:, log_sink:, **_) {
        log_sink.call("real chunk")
        log_sink.call("")            # would crash pre-fix
        log_sink.call("   \n\n  ")   # whitespace-only
        File.write(File.join(workspace_path, "feature.rb"), "def x = 1\n")
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      run = job.workflows.last.steps.find_by(kind: "implement").runs.first
      logs = run.job_logs.pluck(:chunk)
      expect(logs).to include("real chunk")
      expect(logs).not_to include("", "   \n\n  ")
    end
  end

  describe "immutable-source graders" do
    before do
      allow(RunHostAdmission).to receive(:call).and_return(
        RunHostAdmission::Decision.new(action: "admit", reason: "spec", delay: nil, details: {})
      )
    end

    it "uses per-run Solid Queue concurrency keys for distributed immutable-source grader projections" do
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      repository.update!(distributed_workflow_dag_enabled: true)
      workflow = job.workflows.last
      fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 100, state: "succeeded")
      grader = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 101,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        depends_on_ids: [ fanout.id ],
        details: { "name" => "rspec", "command" => "bin/rspec", "required" => true }
      )
      run = grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)

      expect(described_class.concurrency_key_for(run.id)).to eq("run:#{run.id}")
    end

    it "keeps mutable-workspace runs on the per-job Solid Queue concurrency key" do
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      repository.update!(distributed_workflow_dag_enabled: true)
      workflow = job.workflows.last
      grader = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 100,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        details: { "name" => "rspec", "command" => "bin/rspec", "required" => true }
      )
      immutable_run = grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      pinned_run = workflow.steps.find_by!(kind: "implement").runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider
      )

      expect(described_class.concurrency_key_for(immutable_run.id)).to eq("run:#{immutable_run.id}")
      expect(described_class.concurrency_key_for(pinned_run.id)).to eq("job:#{job.id}")
    end

    it "grades an unpublished initial branch through the published implementation checkpoint" do
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      repository.update!(distributed_workflow_dag_enabled: true)
      File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-checkpoint\n")
      allow(SyrusVersion).to receive(:hostname).and_return("worker-checkpoint")
      allow(GithubAuthenticatedGit).to receive(:run) do |repository:, user:, git:, operation_type:, log:, &block|
        block.call("file://#{bare_remote_dir}")
      end
      syrus_yml = <<~YAML
        grade:
          - name: checkpoint-feature
            run: ruby -e 'abort "missing checkpointed feature" unless File.read("feature.rb").include?("hello"); puts "saw checkpointed feature"'
      YAML
      commit_file_to_remote(".syrus.yml", syrus_yml)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(
        RepoDefaultBranchSyrusYml::Result.new(
          config: SyrusYml.new(syrus_yml).parse,
          source: ".syrus.yml",
          note: nil
        )
      )
      allow_any_instance_of(RunJob).to receive(:next_inline_run).and_return(nil)
      allow(RunHostAdmission).to receive(:call).and_return(
        RunHostAdmission::Decision.new(action: "admit", reason: "spec", delay: nil, details: {})
      )
      initial_job = job
      workflow = initial_job.workflows.last
      expect(remote_ref_exists?("refs/heads/#{initial_job.branch_name}")).to be(false)

      RunJob.perform_now(initial_job.initial_run.id)
      implement_run = workflow.steps.find_by!(kind: "implement").runs.order(:id).last
      RunJob.perform_now(implement_run.id)
      fanout_run = nil
      unless workflow.steps.exists?(kind: "grader_fanout")
        collect = Step.create!(
          workflow: workflow,
          kind: "grader_collect",
          position: 102,
          placement_policy: Step::PlacementPolicy::CONTROL_PLANE
        )
        fanout = Step.create!(
          workflow: workflow,
          kind: "grader_fanout",
          position: 101,
          placement_policy: Step::PlacementPolicy::CONTROL_PLANE,
          next_step: collect
        )
        workflow.steps.find_by!(kind: "implement").update!(next_step: fanout)
        fanout_run = fanout.runs.create!(job: initial_job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      end
      fanout_step = workflow.steps.find_by!(kind: "grader_fanout")
      fanout_step.depends_on_steps.reject(&:terminal?).each do |dependency|
        dependency.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      end
      fanout_run ||= fanout_step.runs.order(:id).last
      fanout_run ||= fanout_step.runs.create!(job: initial_job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      RunJob.perform_now(fanout_run.id)
      grader_step = workflow.steps.find_by!(kind: "grader")
      grader_run = grader_step.runs.order(:id).last
      RunJob.perform_now(grader_run.id)

      checkpoint = workflow.steps.find_by!(kind: "implement").runs.first.run_checkpoint
      snapshot = WorkflowSourceSnapshot.find(grader_step.details.fetch("source_snapshot_id"))
      expect(checkpoint).to be_published
      expect(snapshot.source_ref).to start_with("refs/syrus/source-snapshots/runs/")
      expect(snapshot.source_sha).to eq(checkpoint.commit_sha)
      expect(grader_step.details.fetch("source_snapshot")).to include(
        "source_sha" => checkpoint.commit_sha,
        "source_ref" => snapshot.source_ref
      )
      expect(grader_run.reload).to be_succeeded
      expect(grader_run.job_logs.where(kind: "grade_log").pluck(:chunk).join).to include("saw checkpointed feature")
      expect(remote_ref_exists?("refs/heads/#{initial_job.branch_name}")).to be(false)
    end

    it "runs a serial grader against the immutable source snapshot instead of the mutable workflow workspace" do
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      repository.update!(distributed_workflow_dag_enabled: true)
      File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-serial\n")
      allow(SyrusVersion).to receive(:hostname).and_return("worker-serial")
      allow(GithubAuthenticatedGit).to receive(:run) do |repository:, user:, git:, operation_type:, log:, &block|
        block.call("file://#{bare_remote_dir}")
      end
      commit_file_to_remote("source.txt", "snapshot\n")
      immutable_job = Factories.job_record(user: user, repository: repository, issue_number: 77, state: "running")
      workflow = Workflow.create!(
        job: immutable_job,
        user: user,
        trigger_kind: "initial",
        agent_provider: immutable_job.agent_provider
      )
      step = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 0,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        details: {
          "name" => "snapshot-check",
          "command" => <<~'RUBY'.squish,
            ruby -e 'actual = File.read("source.txt");
            abort "mutable workspace used: #{actual.inspect}" unless actual == "snapshot\n";
            puts "validated immutable snapshot"'
          RUBY
          "required" => true,
          "timeout_minutes" => 1
        }
      )
      snapshot = WorkflowSourceSnapshots.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main").strip,
        source_ref: "refs/heads/main",
        tree_sha: sh("git --git-dir=#{bare_remote_dir} rev-parse refs/heads/main^{tree}").strip
      )
      step.update!(details: step.details.merge("source_snapshot_id" => snapshot.id))
      mutable_workspace = WorkflowWorkspace.path_for(workflow)
      FileUtils.mkdir_p(mutable_workspace)
      File.write(mutable_workspace.join("source.txt"), "mutable\n")
      run = step.runs.create!(
        job: immutable_job,
        trigger_kind: workflow.trigger_kind,
        agent_provider: immutable_job.agent_provider
      )

      RunJob.perform_now(run.id)

      expect(run.reload).to be_succeeded
      expect(run.head_sha).to eq(snapshot.source_sha)
      expect(step.reload).to be_succeeded
      expect(step.details.fetch("prepare_cache")).to include(
        "status" => "miss",
        "worker_storage_key" => "storage-serial",
        "source_snapshot_sha" => snapshot.source_sha
      )
      expect(step.details.fetch("immutable_source_checkout")).to include(
        "worker_hostname" => "worker-serial",
        "worker_storage_key" => "storage-serial",
        "source_snapshot_sha" => snapshot.source_sha,
        "prepare_cache_status" => "miss"
      )
      expect(run.job_logs.where(kind: "grade_log").pluck(:chunk).join).to include("validated immutable snapshot")
      expect(workflow.reload.cleaned_up_at).to be_present
    end

    it "persists source snapshot infrastructure failures on immutable grader runs" do
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      repository.update!(distributed_workflow_dag_enabled: true)
      File.write(File.join(@data_root, WorkerStorageIdentity::FILE_NAME), "storage-infra\n")
      allow(SyrusVersion).to receive(:hostname).and_return("worker-infra")

      immutable_job = Factories.job_record(user: user, repository: repository, issue_number: 78, state: "running")
      workflow = Workflow.create!(
        job: immutable_job,
        user: user,
        trigger_kind: "initial",
        agent_provider: immutable_job.agent_provider
      )
      step = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 0,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        details: {
          "name" => "snapshot-check",
          "command" => "true",
          "required" => true,
          "timeout_minutes" => 1
        }
      )
      run = step.runs.create!(
        job: immutable_job,
        trigger_kind: workflow.trigger_kind,
        agent_provider: immutable_job.agent_provider
      )

      expect { RunJob.perform_now(run.id) }
        .to raise_error(WorkflowSourceSnapshots::InfrastructureStateError, /source_snapshot_id/)

      expect(run.reload.run_failure_classification).to have_attributes(
        classification: "source_snapshot_metadata_invalid",
        retryable: true
      )
      expect(run.run_diagnostic).to have_attributes(
        error_class: "WorkflowSourceSnapshots::InfrastructureStateError"
      )
    end
  end

  describe "failure cap (per-Workflow)" do
    it "auto-fails the Workflow when failure_count crosses AppSetting.max_job_failures" do
      AppSetting.current.update!(max_job_failures: 1)
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: true,
                                    outcome: "error_during_execution", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      expect(job.workflows.last.state).to eq("failed")
      # Job stays open — failure cap is per-Workflow now, not per-Job
      expect(job.reload).to be_open
    end

    # Regression: a main-repair preflight fans out 130 graders in parallel
    # waves. Three of them failing tripped the cap and failed the Workflow
    # while 120 were still queued, so the collect Step that judges graders and
    # re-runs infrastructure failures never ran.
    it "does not count a collector-judged grader failure toward the cap" do
      AppSetting.current.update!(max_job_failures: 1)
      grader_job = Factories.job_record(user: user, repository: repository, issue_number: 79, state: "running")
      workflow = Workflow.create!(job: grader_job, user: user, trigger_kind: "main_branch_repair", agent_provider: grader_job.agent_provider, state: "running")
      grader = Step.create!(
        workflow: workflow, kind: "preflight_grader", position: 0,
        details: { "name" => "rspec-ci-1-of-4", "command" => "exit 1", "required" => true, "timeout_minutes" => 1 }
      )
      Step.create!(workflow: workflow, kind: "preflight_grader_collect", position: 1, depends_on_ids: [ grader.id ])
      run = grader.runs.create!(job: grader_job, trigger_kind: workflow.trigger_kind, agent_provider: grader_job.agent_provider)

      begin
        RunJob.perform_now(run.id)
      rescue StandardError
        nil
      end

      expect(grader.reload).to be_failed
      expect(workflow.reload.failure_count).to eq(0)
      expect(workflow).not_to be_failed
    end
  end

  # ----- Pre-pickup cancellation ---------------------------------

  describe "guards" do
    %w[draining updating].each do |drain_state|
      it "defers a queued Run before start when the local macOS worker is #{drain_state}" do
        job
        wf = job.workflows.last
        run = wf.first_step.runs.first
        MacosWorkerDrain.create!(
          worker_storage_key: "storage-a",
          hostname: "mac-mini-a",
          state: drain_state,
          drain_started_at: Time.current,
          desired_git_sha: "abc1234"
        )
        allow(WorkerCapabilities).to receive(:current).and_return(
          capabilities: { "os" => [ "macos" ] },
          diagnostics: {}
        )
        allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-a")
        allow(SyrusVersion).to receive(:hostname).and_return("mac-mini-a")
        expect(RunHostAdmission).not_to receive(:call)

        expect {
          RunJob.perform_now(run.id)
        }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

        expect(run.reload).to be_queued
        expect(wf.reload.artifact("macos_worker_drain_admission")).to include(
          "action" => "defer",
          "reason" => "macos_worker_#{drain_state}",
          "worker_storage_key" => "storage-a",
          "hostname" => "mac-mini-a",
          "desired_git_sha" => "abc1234"
        )
        expect(JobLog.where(run: run).pluck(:chunk)).to include("macOS worker drain deferred before prepare: #{drain_state}")
      end
    end

    describe "macOS release version skew" do
      let(:run) { job.workflows.last.first_step.runs.first }

      before do
        job
        AppSetting.current.update!(macos_worker_desired_release: { "git_sha" => "50d35be290", "rollout" => "immediate" })
      end

      def on_host(os:, git_sha:)
        allow(WorkerCapabilities).to receive(:current).and_return(capabilities: { "os" => [ os ] }, diagnostics: {})
        allow(SyrusVersion).to receive(:current).and_return(git_sha)
      end

      # Regression: a Mac worker still on the previous revision after a deploy
      # ran Runs against the new schema and failed them on a dropped table.
      it "hands a queued Run back while this Mac worker runs another revision than the active release" do
        on_host(os: "macos", git_sha: "16254d1666")
        expect(RunHostAdmission).not_to receive(:call)

        expect { RunJob.perform_now(run.id) }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

        expect(run.reload).to be_queued
        expect(JobLog.where(run: run).pluck(:chunk)).to include(
          "macOS worker runs 16254d1666, but the active release is 50d35be290; waiting for the update before prepare"
        )
      end

      # Regression: the macOS worker claimed Linux-default graders from the
      # shared compute queue and ran them while Linux workers sat idle.
      it "hands back a Run whose placement this worker does not satisfy" do
        on_host(os: "macos", git_sha: "50d35be290")
        ensure_solid_queue_test_tables!
        SolidQueue::Process.create!(
          hostname: "linux-worker", kind: "Worker", name: "linux-worker-1", pid: 123, last_heartbeat_at: Time.current,
          metadata: { "queues" => "runs", "capabilities" => { "os" => [ "linux" ] }, "polling_interval" => 0.1, "pool_size" => 1 }
        )
        expect(RunHostAdmission).not_to receive(:call)

        expect { RunJob.perform_now(run.id) }.to have_enqueued_job(RunJob).with(run.id)

        expect(run.reload).to be_queued
      end

      it "runs a Run whose placement this worker satisfies" do
        on_host(os: "linux", git_sha: "50d35be290")
        job_instance = RunJob.new(run.id)
        job_instance.instance_variable_set(:@run, run)
        job_instance.instance_variable_set(:@step, run.step)

        expect(job_instance.send(:hand_back_incapable_run?)).to be(false)
      end

      it "does not hold back a Mac worker that runs the active release" do
        on_host(os: "macos", git_sha: "50d35be290")
        job_instance = RunJob.new(run.id)
        job_instance.instance_variable_set(:@run, run)
        job_instance.instance_variable_set(:@step, run.step)

        expect(job_instance.send(:defer_for_macos_version_skew?)).to be(false)
      end

      it "never holds back Linux workers, which deploy pins directly" do
        on_host(os: "linux", git_sha: "16254d1666")
        job_instance = RunJob.new(run.id)
        job_instance.instance_variable_set(:@run, run)
        job_instance.instance_variable_set(:@step, run.step)

        expect(job_instance.send(:defer_for_macos_version_skew?)).to be(false)
      end
    end

    # Regression: cancelling a workflow killed its running graders, and each
    # was recorded as a failed run with no exit status.
    it "records a run killed by its workflow's cancellation as cancelled, not failed" do
      allow(WorkerCapabilities).to receive(:current).and_return(capabilities: { "os" => [ "linux" ] }, diagnostics: {})
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      step = run.step
      handler = Class.new do
        define_method(:initialize) { |_run| }
        define_method(:call) do
          step.update_columns(state: "cancelled", finished_at: Time.current)
          wf.update_columns(state: "cancelled", finished_at: Time.current)
          raise Steps::Base::StepFailed, "grader frontend-lint failed (exit )"
        end
      end
      allow(Steps).to receive(:handler_for).and_call_original
      allow(Steps).to receive(:handler_for).with(step.kind).and_return(handler)
      allow(RunHostAdmission).to receive(:call).and_return(RunHostAdmission::Decision.new(action: "admit", reason: nil, delay: nil, details: {}))

      RunJob.perform_now(run.id)

      expect(run.reload).to be_cancelled
      expect(wf.reload).to be_cancelled
    end

    # Regression: a Step cancelled on its own while it ran -- review evidence
    # superseded by a new implementation HEAD cancels the running review with
    # its cascade suppressed and leaves the Workflow running -- had its killed
    # Run cancelled with the normal cascade, which cancelled the whole Workflow.
    [ true, false ].each do |run_already_cancelled|
      it "cancels a run whose step alone was cancelled without cancelling its workflow (run already cancelled: #{run_already_cancelled})" do
        allow(WorkerCapabilities).to receive(:current).and_return(capabilities: { "os" => [ "linux" ] }, diagnostics: {})
        job
        wf = job.workflows.last
        run = wf.first_step.runs.first
        step = run.step
        handler = Class.new do
          define_method(:initialize) { |_run| }
          define_method(:call) do
            step.update_columns(state: "cancelled", finished_at: Time.current)
            ::Run.find(run.id).cancel_without_step_cascade! if run_already_cancelled
            raise Steps::Base::StepFailed, "grader frontend-lint failed (exit )"
          end
        end
        allow(Steps).to receive(:handler_for).and_call_original
        allow(Steps).to receive(:handler_for).with(step.kind).and_return(handler)
        allow(RunHostAdmission).to receive(:call).and_return(RunHostAdmission::Decision.new(action: "admit", reason: nil, delay: nil, details: {}))

        RunJob.perform_now(run.id)

        expect([ run.reload.state, step.reload.state, wf.reload.state ]).to eq(%w[cancelled cancelled running])
      end
    end

    # Regression: after a worker restart lost the workspace, a retried
    # grader_collect crashed on the missing directory and refailed the
    # reopened Workflow before the reconciler could reconstruct it.
    describe "a grader collector whose workspace was lost" do
      let(:wf) { job.workflows.last }
      let!(:collect_step) do
        wf.steps.where.not(id: nil).update_all(state: "succeeded")
        wf.steps.create!(kind: "grader_collect", position: 999, state: "queued")
      end
      let!(:collect_run) do
        collect_step.runs.create!(job: job, user: job.user, trigger_kind: wf.trigger_kind,
                                  agent_provider: wf.agent_provider, state: "queued")
      end

      before do
        wf.update_columns(state: "running", workspace_lifecycle_state: "created", worker_hostname: nil, worker_storage_key: nil)
        FileUtils.rm_rf(WorkflowWorkspace.path_for(wf))
      end

      it "stays queued for workspace reconstruction instead of running" do
        expect(Steps).not_to receive(:handler_for)

        expect { RunJob.perform_now(collect_run.id) }.to have_enqueued_job(RunJob).with(collect_run.id)

        expect(collect_run.reload).to be_queued
        expect(JobLog.where(run: collect_run).pluck(:chunk))
          .to include("step grader_collect is waiting for its lost workspace to be reconstructed")
      end

      it "runs normally when the workspace was never created" do
        wf.update_columns(workspace_lifecycle_state: nil)
        handler = instance_double(Steps::GraderCollect, call: nil)
        allow(Steps).to receive(:handler_for).and_call_original
        allow(Steps).to receive(:handler_for).with("grader_collect").and_return(class_double(Steps::GraderCollect, new: handler))

        RunJob.perform_now(collect_run.id)

        expect(handler).to have_received(:call)
      end
    end

    it "defers a queued Run before start when the selected compute host is saturated" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "local_worker_pressure_critical",
        delay: 30.seconds,
        details: { "hostname" => "worker-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

      expect(run.reload).to be_queued
      expect(wf.reload.artifact("run_host_admission")).to include(
        "action" => "defer",
        "reason" => "local_worker_pressure_critical",
        "hostname" => "worker-a"
      )
      expect(JobLog.where(run: run).pluck(:chunk)).to include("compute host admission deferred before prepare: local_worker_pressure_critical")
    end

    it "keeps a never-started prepare fleet-eligible until another worker passes host admission" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      current_worker = { hostname: "worker-a", storage_key: "storage-a" }
      rejected = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "host_resource_semaphore_busy",
        delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      admitted = RunHostAdmission::Decision.new(
        action: "admit",
        reason: "host_resources_available",
        delay: nil,
        details: { "hostname" => "worker-b", "worker_storage_key" => "storage-b" }
      )
      allow(SyrusVersion).to receive(:hostname) { current_worker.fetch(:hostname) }
      allow(WorkerStorageIdentity).to receive(:queue_key) { current_worker.fetch(:storage_key) }
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(rejected, admitted)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

      expect(run.reload).to be_queued
      expect(wf.reload).to have_attributes(worker_hostname: nil, worker_storage_key: nil)
      expect(wf.artifact("run_host_admission")).to include("deferral_count" => 1)

      current_worker.replace(hostname: "worker-b", storage_key: "storage-b")
      identity_seen_by_prepare = nil
      allow_any_instance_of(Steps::Prepare).to receive(:call) do
        identity_seen_by_prepare = wf.reload.slice(:worker_hostname, :worker_storage_key)
        raise Steps::Base::CannotProceed, "stop after affinity assertion"
      end

      RunJob.perform_now(run.id)

      expect(identity_seen_by_prepare).to eq(
        "worker_hostname" => "worker-b",
        "worker_storage_key" => "storage-b"
      )
      expect(wf.reload).to have_attributes(worker_hostname: "worker-b", worker_storage_key: "storage-b")
    end

    it "immediately reroutes host-rejected work while preserving urgent priority" do
      job.update!(priority: "urgent")
      wf = job.workflows.last
      run = wf.first_step.runs.first
      admission = RunHostAdmission::Decision.new(
        action: "defer", reason: "host_resource_semaphore_busy", delay: 30.seconds,
        details: { "hostname" => "worker-a" }
      )
      routing = DistributedRunAdmissionRouter::Decision.new(
        action: "reroute", queue_name: "worker-worker-b", delay: nil,
        details: {
          "routing_decision" => "healthy_alternative",
          "routed_worker" => "worker-b",
          "routed_worker_storage_key" => "storage-b"
        }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(admission)
      allow(DistributedRunAdmissionRouter).to receive(:call).with(run: run, admission: admission).and_return(routing)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("worker-worker-b")

      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(queued[:priority]).to eq(Job::PRIORITY_TO_SQ.fetch("urgent"))
      expect(queued[:at]).to be_nil
      expect(wf.reload.artifact("run_host_admission")).to include(
        "action" => "reroute",
        "routing_decision" => "healthy_alternative",
        "routed_queue" => "worker-worker-b"
      )
    end

    it "does not enqueue a reroute after the Run is cancelled" do
      job
      run = job.workflows.last.first_step.runs.first
      run.cancel!
      run.save!

      expect {
        RunJob.new.send(:dispatch_run, run.id, queue: "worker-worker-b")
      }.not_to have_enqueued_job(RunJob)
    end


    it "logs memory tuning guidance only once when memory binds host admission" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      decision = RunHostAdmission::Decision.new(
        action: "defer", reason: "host_resource_semaphore_busy", delay: 30.seconds,
        details: { "hostname" => "worker-a", "resource_guard_binding_terms" => [ "memory_reservation" ] }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      2.times { RunJob.perform_now(run.id) }

      guidance = JobLog.where(run: run).where("chunk LIKE ?", "host memory admission is binding;%")
      expect(guidance.pluck(:chunk)).to eq([
        "host memory admission is binding; tune SYRUS_WORKER_CPU_LIMIT to change capacity-unit reservations or increase the Docker memory setting"
      ])
    end

    it "does not recommend changing CPU limits for deterministic memory fallback" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      decision = RunHostAdmission::Decision.new(
        action: "defer", reason: "host_resource_semaphore_busy", delay: 30.seconds,
        details: {
          "hostname" => "worker-a",
          "resource_guard_binding_terms" => [ "measured_memory" ],
          "candidate_memory_evidence_source" => "deterministic_compute_fallback"
        }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      RunJob.perform_now(run.id)

      expect(JobLog.where(run: run).pluck(:chunk)).to include(
        "host memory admission is binding; collect command resource samples to replace the bounded deterministic fallback or increase the Docker memory setting"
      )
    end

    # The deferral count lives in one per-Workflow artifact keyed by run_id,
    # and restarted at 1 whenever a different Run recorded a deferral. Sibling
    # Runs of one pinned Workflow (parallel grader shards deferring each other
    # on the same host) therefore reset each other's count on every round, and
    # the budget that bounds the deferral loop was never reached.
    it "counts each pinned Run's deferrals separately so siblings cannot reset each other" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      sibling_step = wf.steps.create!(kind: "grader", position: 50, state: "queued")
      sibling = sibling_step.runs.create!(job: job, trigger_kind: wf.trigger_kind, agent_provider: wf.agent_provider, state: "queued")
      wf.update!(worker_hostname: "worker-a", worker_storage_key: "storage-a")
      decision = RunHostAdmission::Decision.new(
        action: "defer", reason: "host_resource_semaphore_busy", delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      allow(RunHostAdmission).to receive(:call).and_return(decision)

      RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET.times do
        break if wf.reload.worker_storage_key.nil?

        RunJob.perform_now(run.id)
        RunJob.perform_now(sibling.id)
      end

      expect(wf.reload.worker_storage_key).to be_nil
    end

    it "drops storage affinity after a pinned Run exhausts its host admission deferral budget" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      wf.update!(
        worker_hostname: "worker-a",
        worker_storage_key: "storage-a",
        artifacts: {
          "run_host_admission" => {
            "reason" => "host_admission_staggering",
            "run_id" => run.id,
            "deferral_count" => RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET - 1,
            "first_deferred_at" => 20.minutes.ago.iso8601
          }
        }
      )
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "host_resource_semaphore_busy",
        delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

      expect(run.reload).to be_queued
      expect(wf.reload.worker_hostname).to be_nil
      expect(wf.worker_storage_key).to be_nil
      expect(wf.artifact("run_host_admission")).to include(
        "action" => "defer",
        "reason" => "host_resource_semaphore_busy",
        "deferral_count" => RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET,
        "deferral_budget" => RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET
      )
    end

    it "deletes stale resume queue rows when a pinned Run exhausts its host admission deferral budget" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      wf.update!(
        worker_hostname: "worker-a",
        worker_storage_key: "storage-a",
        artifacts: {
          "run_host_admission" => {
            "reason" => "local_worker_pressure_critical",
            "run_id" => run.id,
            "deferral_count" => RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET - 1,
            "first_deferred_at" => 20.minutes.ago.iso8601
          }
        }
      )
      stale_queue_job = SolidQueue::Job.create!(
        class_name: "RunJob",
        queue_name: "resume-storage-a",
        priority: run.solid_queue_priority,
        arguments: { "arguments" => [ run.id ] },
        scheduled_at: 30.seconds.from_now,
        created_at: 1.minute.ago,
        updated_at: 1.minute.ago
      )
      SolidQueue::ScheduledExecution.find_or_create_by!(job: stale_queue_job) do |execution|
        execution.priority = stale_queue_job.priority
        execution.queue_name = stale_queue_job.queue_name
        execution.scheduled_at = stale_queue_job.scheduled_at
        execution.created_at = stale_queue_job.created_at
      end
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "local_worker_pressure_critical",
        delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

      expect(SolidQueue::Job.where(id: stale_queue_job.id)).to be_empty
      expect(SolidQueue::ScheduledExecution.where(job_id: stale_queue_job.id)).to be_empty
      expect(wf.reload.worker_storage_key).to be_nil
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "counts repeated pinned host admission deferrals across changing reasons" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      wf.update!(
        worker_hostname: "worker-a",
        worker_storage_key: "storage-a",
        artifacts: {
          "run_host_admission" => {
            "reason" => "landing_work_has_priority",
            "run_id" => run.id,
            "deferral_count" => 7,
            "first_deferred_at" => 4.minutes.ago.iso8601
          }
        }
      )
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "host_admission_staggering",
        delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id)

      expect(wf.reload.worker_storage_key).to be_present
      expect(wf.artifact("run_host_admission")).to include(
        "reason" => "host_admission_staggering",
        "deferral_count" => 8
      )
    end

    it "does not spend a pinned Run's host admission budget using a previous Run's deferrals" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      wf.update!(
        worker_hostname: "worker-a",
        worker_storage_key: "storage-a",
        artifacts: {
          "run_host_admission" => {
            "reason" => "local_worker_pressure_critical",
            "run_id" => run.id + 10_000,
            "deferral_count" => RunJob::PINNED_HOST_ADMISSION_DEFERRAL_BUDGET,
            "first_deferred_at" => 20.minutes.ago.iso8601
          }
        }
      )
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "local_worker_pressure_critical",
        delay: 30.seconds,
        details: { "hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id)

      expect(wf.reload.worker_hostname).to be_present
      expect(wf.worker_storage_key).to be_present
      expect(wf.artifact("run_host_admission")).to include(
        "run_id" => run.id,
        "deferral_count" => 1
      )
    end

    it "does not append duplicate host admission deferral logs for the same queued run" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      decision = RunHostAdmission::Decision.new(
        action: "defer",
        reason: "local_worker_pressure_critical",
        delay: 30.seconds,
        details: { "hostname" => "worker-a" }
      )
      allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

      2.times { RunJob.perform_now(run.id) }

      expect(JobLog.where(run: run, kind: "system", chunk: "compute host admission deferred before prepare: local_worker_pressure_critical").count).to eq(1)
    end

    it "abandons a Run as cancelled when its Workflow is already terminal" do
      job
      wf = job.workflows.last
      run = wf.first_step.runs.first
      wf.update!(state: "succeeded")  # somebody else terminated the workflow
      RunJob.perform_now(run.id)
      expect(run.reload.state).to eq("cancelled")
    end

    it "fails the Run with worker_died on re-entrancy (already running)" do
      job
      run = job.workflows.last.first_step.runs.first
      run.update!(state: "running", started_at: 1.hour.ago)
      RunJob.perform_now(run.id)
      run.reload
      expect(run.state).to eq("failed")
      expect(run.agent_outcome).to eq("worker_died")
    end

    it "cancelling a Run cascades to its Step + Workflow (operator Stop)" do
      job
      wf = job.workflows.last
      step = wf.first_step
      run = step.runs.first
      run.update!(state: "running", started_at: 1.minute.ago)
      run.cancel!
      run.save!
      expect(run.reload.state).to eq("cancelled")
      expect(step.reload.state).to eq("cancelled")
      expect(wf.reload.state).to eq("cancelled")
    end
  end

  # ----- helpers --------------------------------------------------

  # Drain queued Runs across all workflows on this Job until none
  # remain. Each step's success creates the next step's Run via
  # Step#after_update_commit → StepDispatcher.advance_from. The
  # test adapter doesn't auto-perform those; we drive each in
  # sequence. Failed steps stop chain advancement (the dispatcher's
  # after_update_commit only fires on succeeded), so the loop ends
  # naturally on failure too.
  def drain_workflow!(job)
    loop do
      runs = job.reload.workflows.includes(steps: :runs).flat_map { |w|
        w.steps.flat_map { |s| s.runs.where(state: "queued").to_a }
      }
      break if runs.empty?
      RunJob.perform_now(runs.first.id) rescue nil
    end
  end

  def default_agent_runner(workspace_path:, **_)
    current = Thread.current[:syrus_current_run]
    file = File.join(workspace_path, "feature.rb")
    case current.step.kind
    when "implement", "landing_fix", "manual"
      File.write(file, "def greet = 'hello'\n")
    when "respond", "analyze_and_fix"
      # Follow-up step on an existing branch — append to the
      # already-committed feature.rb so the diff is non-empty.
      File.open(file, "a") { |f| f.puts "# addressed feedback at #{Time.now.to_f}" }
    when "summarize", "summarize_amend"
      current.update!(
        agent_pr_title: "Add greeting helper",
        agent_pr_body:  "Adds a tiny greet helper used by the welcome page.",
        agent_summary:  "Implemented greet."
      )
    when "test_plan"
      current.workflow.set_artifact!("test_plan", { steps: [ "Run bin/rspec" ], notes: nil })
    when "refresh_job_metadata"
      current.workflow.set_artifact!("job_metadata", {
        "changed" => false,
        "intent_revision_reason" => "Feedback only tightened implementation details."
      })
    when "agent_rebase"
      sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
    end
    AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
  end

  def seed_remote_with_initial_commit(bare_path)
    Dir.mktmpdir("syrus-seed") do |seed|
      sh("git init -q -b main #{seed}")
      sh("git -C #{seed} commit --allow-empty -q -m 'initial'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def commit_file_to_remote(path, content)
    Dir.mktmpdir("syrus-seed-update") do |seed|
      sh("git clone -q #{bare_remote_dir} #{seed}")
      full_path = File.join(seed, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
      sh("git -C #{seed} add #{path}")
      sh("git -C #{seed} commit -q -m 'add #{path}'")
      sh("git -C #{seed} push -q origin main")
    end
  end

  def create_branch_to_remote(branch, files)
    Dir.mktmpdir("syrus-branch-seed") do |seed|
      sh("git clone -q #{bare_remote_dir} #{seed}")
      sh("git -C #{seed} checkout -q -b #{branch}")
      files.each do |path, content|
        full_path = File.join(seed, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, content)
        sh("git -C #{seed} add #{path}")
      end
      sh("git -C #{seed} commit -q -m 'seed #{branch}'")
      sh("git -C #{seed} push -q origin #{branch}")
    end
  end

  def remote_ref_exists?(ref)
    system("git", "--git-dir=#{bare_remote_dir}", "show-ref", "--verify", "--quiet", ref)
  end

  def job_with_single_run(step_kind:)
    Factories.job_with_run(
      user: user,
      repository: repository,
      state: "queued",
      workflow_attrs: { trigger_kind: "manual" },
      step_attrs: { kind: step_kind },
      run_attrs: { trigger_kind: "manual" }
    )
  end

  def initialize_workspace_repo(workflow, files = {})
    path = WorkflowWorkspace.path_for(workflow)
    FileUtils.mkdir_p(path)
    sh("git init -q -b main #{path}")
    sh("git -C #{path} config user.email test@example.com")
    sh("git -C #{path} config user.name Test")
    File.write(path.join("README.md"), "seed\n")
    sh("git -C #{path} add README.md")
    sh("git -C #{path} commit -q -m initial")
    sh("git -C #{path} remote add origin #{path}")
    sh("git -C #{path} fetch -q origin main:refs/remotes/origin/main")
    sh("git -C #{path} checkout -q -b #{workflow.job.branch_name || "syrus/direct-#{workflow.job.id}"}")
    files.each do |relative_path, content|
      full_path = path.join(relative_path)
      FileUtils.mkdir_p(full_path.dirname)
      File.write(full_path, content)
      sh("git -C #{path} add #{relative_path}")
    end
    sh("git -C #{path} commit -q -m 'feature changes'") if files.any?
    path
  end

  def implemented_job_with_branch
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 123,
      branch_name: "syrus/issue-42-implemented",
      state: "implemented"
    ).tap do |record|
      create_branch_to_remote(record.branch_name, "feature.rb" => "def greet = 'hello'\n")
    end
  end

  def retriable_job_with_branch
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 123,
      branch_name: "syrus/issue-42-retry",
      state: "failed"
    ).tap do |record|
      Workflow.create!(
        job: record,
        user: user,
        trigger_kind: "initial",
        agent_provider: record.agent_provider,
        state: "failed",
        started_at: 10.minutes.ago,
        finished_at: 9.minutes.ago
      )
      create_branch_to_remote(record.branch_name, "feature.rb" => "def greet = 'hello'\n")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "seed@example.com",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "seed@example.com" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end

  describe "SIGTERM shutdown at step boundary" do
    it "exits cleanly at the inter-step boundary without failing the successor Run" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n") if current.step.kind == "implement"
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      # Simulate SIGTERM arriving right after implement completes: set the shutdown
      # flag when next_inline_run is called while the current step is implement.
      allow_any_instance_of(RunJob).to receive(:next_inline_run).and_wrap_original do |original, *args|
        result = original.call(*args)
        run_job = original.receiver
        if result && run_job.instance_variable_get(:@step)&.kind == "implement"
          run_job.instance_variable_set(:@shutdown_requested, true)
        end
        result
      end

      job
      RunJob.perform_now(job.initial_run.id)

      wf = job.workflows.last
      implement_step = wf.steps.find_by(kind: "implement")
      expect(implement_step.reload.state).to eq("succeeded")

      # The successor step's Run is still queued — not started or failed — because
      # RunJob exited cleanly at the step boundary instead of advancing.
      successor_run = implement_step.next_step.runs.first
      expect(successor_run.state).to eq("queued")

      # Workflow is not failed (it still has queued work to do)
      expect(wf.reload.state).not_to eq("failed")
    end

    it "does not start a new step if shutdown is requested before perform_step" do
      step_kinds_executed = []
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        step_kinds_executed << current.step.kind
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n") if current.step.kind == "implement"
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      # Simulate SIGTERM arriving after implement's Run is picked up as next_run
      # but before its perform_step is called: set the flag while @step is still
      # "implement" (the step that just succeeded), so the top-of-loop guard fires.
      allow_any_instance_of(RunJob).to receive(:next_inline_run).and_wrap_original do |original, *args|
        result = original.call(*args)
        run_job = original.receiver
        if result && run_job.instance_variable_get(:@step)&.kind == "prepare"
          run_job.instance_variable_set(:@shutdown_requested, true)
        end
        result
      end

      job
      RunJob.perform_now(job.initial_run.id)

      wf = job.workflows.last
      prepare_step = wf.steps.find_by(kind: "prepare")
      expect(prepare_step.reload.state).to eq("succeeded")

      # implement's Run is queued — the top-of-loop `break if @shutdown_requested`
      # fired before perform_step was called for implement.
      implement_step = wf.steps.find_by(kind: "implement")
      expect(implement_step.runs.first.state).to eq("queued")

      # Agent runner should never have been called for implement
      expect(step_kinds_executed).not_to include("implement")
    end
  end

  describe "global agent concurrency cap" do
    include ActiveJob::TestHelper

    let(:other_job) { Factories.job(repository: repository, issue_number: 43) }
    # The budget counts runs that hold an agent SESSION, so these have to sit on
    # an agentic step. They used to use Job#initial_run, which is the `prepare`
    # run -- non-agentic, and only counted because the old scope keyed on the
    # workflow's trigger kind rather than the step.
    let!(:queued_run) { agentic_run_for(job) }

    def agentic_run_for(target_job)
      workflow = target_job.latest_workflow
      step = workflow.steps.find_by(kind: "implement") ||
             Step.create!(workflow: workflow, kind: "implement", position: 99)
      Run.create!(
        job: target_job,
        step: step,
        user: target_job.user,
        trigger_kind: workflow.trigger_kind,
        agent_provider: target_job.agent_provider
      )
    end

    def running_agent_run!
      run = agentic_run_for(other_job)
      run.start!
      run.save!
      run
    end

    def main_grader_run!
      main_grader_job = Job.create!(
        user: user,
        repository: repository,
        kind: "main_grader",
        issue_title: "main_grader:abc123",
        issue_number: nil
      )
      workflow = Workflow.create!(
        job: main_grader_job,
        user: user,
        trigger_kind: "main_grader"
      )
      step = Step.create!(workflow: workflow, kind: "grader_fanout", position: 0)
      Run.create!(
        job: main_grader_job,
        step: step,
        trigger_kind: "main_grader",
        agent_provider: main_grader_job.agent_provider
      )
    end

    def main_branch_repair_run!
      repair_job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: Job::MAIN_BRANCH_REPAIR_TITLE
      )
      workflow = Workflow.create!(
        job: repair_job,
        user: user,
        trigger_kind: "main_branch_repair"
      )
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0)
      Run.create!(
        job: repair_job,
        step: step,
        trigger_kind: "main_branch_repair",
        agent_provider: repair_job.agent_provider
      )
    end

    it "does not defer when the cap is 0 (unlimited)" do
      AppSetting.current.update!(max_concurrent_agent_runs: 0)
      running_agent_run!

      expect(RunJob.new.send(:defer_for_agent_concurrency?, queued_run.id)).to be(false)
    end
    it "skips the global cap when admission control is disabled" do
      AppSetting.current.update!(workflow_admission_control_enabled: false, max_concurrent_agent_runs: 1)
      running_agent_run!

      expect {
        expect(RunJob.new.send(:defer_for_agent_concurrency?, queued_run.id)).to be(false)
      }.not_to have_enqueued_job(RunJob)
    end

    it "skips actor pacing when admission control is disabled" do
      AppSetting.current.update!(workflow_admission_control_enabled: false)
      allow(Admission::FairShare).to receive(:for)

      expect {
        expect(RunJob.new.send(:defer_for_actor_share?, queued_run.id)).to be(false)
      }.not_to have_enqueued_job(RunJob)
      expect(Admission::FairShare).not_to have_received(:for)
    end

    it "does not defer a Job because the user has recorded Run and chat costs" do
      AppSetting.current.update!(workflow_admission_control_enabled: true, max_concurrent_agent_runs: 3)
      spent_run = agentic_run_for(other_job)
      spent_run.update_columns(cost_usd: 1_000, finished_at: Time.current)
      ChatSession.create!(
        user: queued_run.user,
        repository: repository,
        cumulative_cost_usd: 1_000,
        daily_cost_usd: 1_000,
        daily_cost_date: Date.current
      )
      allow(Admission::FairShare).to receive(:for).and_return(
        Admission::FairShare::Result.new(
          over_share: false, active: 0, share: 3, contenders: 1, limit: 3
        )
      )

      expect {
        expect(RunJob.new.send(:defer_for_actor_share?, queued_run.id)).to be(false)
      }.not_to have_enqueued_job(RunJob)
    end

    it "does not defer when running agent Runs are below the cap" do
      AppSetting.current.update!(max_concurrent_agent_runs: 2)
      running_agent_run!  # 1 running < 2

      expect(RunJob.new.send(:defer_for_agent_concurrency?, queued_run.id)).to be(false)
    end

    it "defers and re-enqueues when the cap is met, leaving the Run queued" do
      AppSetting.current.update!(max_concurrent_agent_runs: 1)
      other_job.update!(priority: "urgent")
      running_agent_run!  # 1 running >= cap 1

      clear_enqueued_jobs
      deferred = nil
      expect {
        deferred = RunJob.new.send(:defer_for_agent_concurrency?, queued_run.id)
      }.to have_enqueued_job(RunJob).with(queued_run.id)
      expect(deferred).to be(true)
      expect(queued_run.reload.state).to eq("queued")
    end

    it "does not defer main_grader runs when urgent user work saturates the cap" do
      AppSetting.current.update!(max_concurrent_agent_runs: 1)
      other_job.update!(priority: "urgent")
      running_agent_run!
      main_grader_run = main_grader_run!

      clear_enqueued_jobs
      expect {
        expect(RunJob.new.send(:defer_for_agent_concurrency?, main_grader_run.id)).to be(false)
      }.not_to have_enqueued_job(RunJob)
      expect(main_grader_run.reload.state).to eq("queued")
    end

    it "does not defer main_branch_repair runs when user work saturates the cap" do
      AppSetting.current.update!(max_concurrent_agent_runs: 1)
      running_agent_run!
      repair_run = main_branch_repair_run!

      clear_enqueued_jobs
      expect {
        expect(RunJob.new.send(:defer_for_agent_concurrency?, repair_run.id)).to be(false)
      }.not_to have_enqueued_job(RunJob)
      expect(repair_run.reload.state).to eq("queued")
    end

    it "preserves main_grader priority when delayed re-enqueue is needed" do
      main_grader_run = main_grader_run!
      urgent_priority = Job::PRIORITY_TO_SQ["urgent"]

      clear_enqueued_jobs
      RunJob.new.send(:defer_run, main_grader_run.id, 15.seconds)
      run_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == RunJob }

      expect(run_jobs.last[:priority]).to be < urgent_priority
    end

    it "delays mutable workflow retries onto the recorded storage-affinity queue" do
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "initial",
        agent_provider: job.agent_provider,
        state: "running",
        worker_storage_key: "storage-main"
      )
      step = Step.create!(
        workflow: workflow,
        kind: "summarize",
        position: 1,
        placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
      )
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      allow(InstanceVersion).to receive(:worker_queue_live?).with("resume-storage-main").and_return(true)
      ensure_solid_queue_test_tables!
      SolidQueue::Process.create!(
        hostname: "worker-main",
        kind: "worker",
        last_heartbeat_at: Time.current,
        metadata: { "queues" => [ "resume-storage-main" ], "capabilities" => { "os" => [ "linux" ] } },
        name: "worker-main:1",
        pid: 123,
        created_at: Time.current
      )
      run_job = RunJob.new
      allow(run_job).to receive(:queue_name).and_return("runs")

      clear_enqueued_jobs
      expect {
        run_job.send(:defer_run, run.id, 15.seconds)
      }.to have_enqueued_job(RunJob).with(run.id).on_queue("resume-storage-main")
    end

    it "classifies runs-queue trigger kinds, excluding landing and merge workflows" do
      kinds = Workflow.runs_queue_trigger_kinds

      expect(kinds).to include("initial", "pr_comment", "retry", "ci_failure", "main_grader", "main_branch_repair")
      expect(kinds).not_to include("auto_merge", "merge_train", "rebase", "stack_rebase")
      expect(queued_run.agent_queue?).to be(true)
    end
  end

  describe "inline successor routing" do
    include ActiveJob::TestHelper

    around do |example|
      prior = Thread.current[Run::INLINE_HELD_RUN_IDS]
      example.run
    ensure
      Thread.current[Run::INLINE_HELD_RUN_IDS] = prior
    end

    it "defers a queued collect run until every grader dependency is terminal" do
      repository.update!(distributed_workflow_dag_enabled: true)
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "merge_train",
        agent_provider: job.agent_provider,
        state: "running"
      )
      fanout = Step.create!(
        workflow: workflow,
        kind: "grader_fanout",
        position: 0,
        state: "succeeded",
        started_at: 3.minutes.ago,
        finished_at: 2.minutes.ago,
        placement_policy: Step::PlacementPolicy::CONTROL_PLANE
      )
      passed_grader = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 1,
        state: "succeeded",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        depends_on_ids: [ fanout.id ],
        details: { "name" => "website-build", "required" => true }
      )
      running_grader = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 2,
        state: "running",
        started_at: 1.minute.ago,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        depends_on_ids: [ fanout.id ],
        details: { "name" => "rspec", "required" => true }
      )
      collect = Step.create!(
        workflow: workflow,
        kind: "grader_collect",
        position: 3,
        placement_policy: Step::PlacementPolicy::CONTROL_PLANE,
        depends_on_ids: [ passed_grader.id, running_grader.id ]
      )
      collect_run = collect.runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider
      )

      clear_enqueued_jobs
      expect {
        RunJob.perform_now(collect_run.id)
      }.to have_enqueued_job(RunJob).with(collect_run.id).on_queue("merges")

      expect(collect.reload).to be_queued
      expect(collect_run.reload).to be_queued
      expect(workflow.reload).to be_running
    end

    it "does not inline a mutable successor on a worker that lacks the workflow workspace" do
      repository.update!(distributed_workflow_dag_enabled: true)
      Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
        feature.category = "Operations"
        feature.name = "Distributed workflow DAG"
      end.update!(enabled: true)
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "merge_train",
        agent_provider: job.agent_provider,
        state: "running",
        worker_storage_key: "storage-main"
      )
      collect = Step.create!(
        workflow: workflow,
        kind: "grader_collect",
        position: 1,
        placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
      )
      grader = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 0,
        next_step_id: collect.id,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        state: "failed",
        details: { "name" => "rspec", "required" => true }
      )
      current_run = grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed")
      collect_run = collect.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "queued")
      run_job = RunJob.new
      run_job.instance_variable_set(:@workflow, workflow)
      run_job.instance_variable_set(:@step, grader)
      run_job.instance_variable_set(:@run, current_run)
      allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-grader")
      allow(InstanceVersion).to receive(:worker_queue_live?).with("resume-storage-main").and_return(true)
      # Created while this perform drove the workflow, so it holds the Run.
      Thread.current[Run::INLINE_HELD_RUN_IDS] = [ collect_run.id ]

      clear_enqueued_jobs
      result = nil
      expect {
        result = run_job.send(:next_inline_run)
        # Re-enqueued onto the workflow's resume queue rather than the generic
        # merges queue: RunQueueResolver routes a Run whose Workflow owns
        # on-disk storage to the worker holding it, which is the whole reason
        # this successor is not inlined here.
      }.to have_enqueued_job(RunJob).with(collect_run.id).on_queue("resume-storage-main")

      expect(result).to be_nil
      expect(collect_run.reload).to be_queued
    end

    it "inlines a mutable successor when the current worker owns the workflow workspace" do
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "merge_train",
        agent_provider: job.agent_provider,
        state: "running",
        worker_storage_key: "storage-main"
      )
      collect = Step.create!(
        workflow: workflow,
        kind: "grader_collect",
        position: 1,
        placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
      )
      build = Step.create!(
        workflow: workflow,
        kind: "merge_train_build",
        position: 0,
        next_step_id: collect.id,
        placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE,
        state: "succeeded"
      )
      current_run = build.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded")
      collect_run = collect.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "queued")
      run_job = RunJob.new
      run_job.instance_variable_set(:@workflow, workflow)
      run_job.instance_variable_set(:@step, build)
      run_job.instance_variable_set(:@run, current_run)
      allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-main")
      Thread.current[Run::INLINE_HELD_RUN_IDS] = [ collect_run.id ]

      clear_enqueued_jobs

      expect(run_job.send(:next_inline_run)).to eq(collect_run)
      expect(enqueued_jobs.select { |entry| entry[:job] == RunJob }).to be_empty
    end
  end
end
