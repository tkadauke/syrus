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
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  before(:context) do
    @seed_bare_remote_dir = Pathname.new(Dir.mktmpdir("syrus-bare-seed"))
    seed_remote_with_initial_commit(@seed_bare_remote_dir)
  end

  after(:context) do
    FileUtils.rm_rf(@seed_bare_remote_dir) if @seed_bare_remote_dir
  end

  before do
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
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/123").with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 123, state: "open", merged: false, body: "Existing PR body" }.to_json
    )
    @pr_update_stub = stub_request(:patch, "https://api.github.com/repos/acme/widgets/pulls/123").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 123, state: "open", body: "Existing PR body" }.to_json
    )

    RunJob.agent_runner = method(:default_agent_runner)

    @data_root = Dir.mktmpdir("syrus-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    RunJob.agent_runner = nil
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
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
  end

  # ----- Initial workflow ----------------------------------------

  describe "Initial workflow (issue → PR)" do
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
        [ "grader_fanout",    "succeeded" ],
        [ "grader_collect",   "succeeded" ],
        [ "coverage_analyze", "succeeded" ],
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
      expect(full).to include("Co-Authored-By: Ada Lovelace <ada@example.com>")

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip
      expect(author).to eq("Ada Lovelace <ada@example.com>")

      expect(WorkflowWorkspace.path_for(wf)).not_to exist
    end

    it "authors commits as the App bot when the App is registered and installed" do
      AppSetting.current.update!(github_app_id: 12_345, github_app_slug: "tkadauke-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      allow_any_instance_of(Installation).to receive(:fresh_token).and_return("ghs_installation")

      job; drain_workflow!(job)

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip

      expect(author).to eq("tkadauke-syrus[bot] <tkadauke-syrus[bot]@users.noreply.github.com>")
    end

    it "workspace stays on disk when the Workflow fails (retry-from-failed-step needs it)" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: true, outcome: "error_during_execution", final_text: nil, session_id: nil)
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
        [ "grader_fanout",        "succeeded" ],
        [ "grader_collect",       "succeeded" ],
        [ "coverage_analyze",     "succeeded" ],
        [ "coverage_pr_comment",  "succeeded" ],
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
      expect(kinds_states[1]).to eq([ "agent_rebase", "cancelled" ])
      expect(kinds_states[2]).to eq([ "force_push",   "succeeded" ])
    end
  end

  # ----- Cron Job (scheduled task) -------------------------------

  describe "Cron Job (scheduled task fire)" do
    let(:scheduled_task) do
      ScheduledTask.create!(
        user: user, repository: repository,
        name: "Sweep dead code", prompt: "Look for dead code.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
    end

    it "runs implement → summarize → pr_open with a pre-rendered prompt and opens a PR" do
      result = ScheduledTaskFire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      job.reload

      wf = job.workflows.last
      expect(wf.state).to eq("succeeded")
      expect(job.pr_number).to eq(123)
      expect(job.branch_name).to start_with("syrus/scheduled-#{scheduled_task.id}-")
    end

    it "does not add a Co-Authored-By trailer for cron jobs" do
      result = ScheduledTaskFire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      full = `git --git-dir=#{bare_remote_dir} log -1 --format='%B' #{job.branch_name}`.strip

      expect(full).not_to include("Co-Authored-By:")
    end

    it "no-changes path: agent surveys, finds nothing → Run fails (implement step), Workflow fails, Job → no_change_needed" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        # Don't write anything — no diff.
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      result = ScheduledTaskFire.new(scheduled_task).call
      job = result.job

      drain_workflow!(job)
      job.reload

      wf = job.workflows.last
      expect(wf.state).to eq("failed")
      implement_run = wf.steps.find_by(kind: "implement").runs.first
      expect(implement_run.state).to eq("failed")
      expect(job.state).to eq("no_change_needed")
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
    it "Run + Step + Workflow fail; Job → no_change_needed; no PR opened" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      expect(job.workflows.last.state).to eq("failed")
      expect(job.reload.state).to eq("no_change_needed")
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

  describe "AutoMerge workflow" do
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
  end

  # ----- Pre-pickup cancellation ---------------------------------

  describe "guards" do
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
    current = Run.last
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

    def running_agent_run!
      run = other_job.initial_run
      run.start!
      run.save!
      run
    end

    it "does not defer when the cap is 0 (unlimited)" do
      AppSetting.current.update!(max_concurrent_agent_runs: 0)
      running_agent_run!

      expect(RunJob.new.send(:defer_for_agent_concurrency?, job.initial_run.id)).to be(false)
    end

    it "does not defer when running agent Runs are below the cap" do
      AppSetting.current.update!(max_concurrent_agent_runs: 2)
      running_agent_run!  # 1 running < 2

      expect(RunJob.new.send(:defer_for_agent_concurrency?, job.initial_run.id)).to be(false)
    end

    it "defers and re-enqueues when the cap is met, leaving the Run queued" do
      AppSetting.current.update!(max_concurrent_agent_runs: 1)
      running_agent_run!  # 1 running >= cap 1

      clear_enqueued_jobs
      deferred = nil
      expect {
        deferred = RunJob.new.send(:defer_for_agent_concurrency?, job.initial_run.id)
      }.to have_enqueued_job(RunJob).with(job.initial_run.id)
      expect(deferred).to be(true)
      expect(job.initial_run.reload.state).to eq("queued")
    end

    it "classifies runs-queue trigger kinds, excluding landing and merge workflows" do
      kinds = Workflow.runs_queue_trigger_kinds

      expect(kinds).to include("initial", "pr_comment", "retry", "ci_failure", "main_grader")
      expect(kinds).not_to include("auto_merge", "merge_train", "rebase", "stack_rebase")
      expect(job.initial_run.agent_queue?).to be(true)
    end
  end
end
