require "rails_helper"
require "tmpdir"
require "fileutils"

# Integration tests for the Workflow → Step → Run pipeline driven
# through RunJob. The agent_runner is stubbed (no real claude
# subprocess) but everything else runs for real: handlers,
# dispatcher, WorkflowWorkspace, git, push to a local bare repo,
# WebMock-stubbed GitHub PR creation. The bare repo's state is
# the ground truth for "did the agent's work make it to origin?".
RSpec.describe RunJob do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-bare")) }
  let(:user) { Factories.user(name: "Ada Lovelace", github_handle: "ada", email_address: "ada@example.com", github_token: "ghp_test_token", claude_oauth_token: "oat-test") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets",
                         default_branch: "main", trigger_label: "syrus", polling_enabled: true)
  end
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  before do
    seed_remote_with_initial_commit(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")

    stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 42, title: "Add greeting helper", body: "We need a greeting helper.", state: "open" }.to_json
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
    PrSummarizer.runner = method(:default_pr_summarizer_runner)

    @data_root = Dir.mktmpdir("syrus-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    RunJob.agent_runner = nil
    PrSummarizer.runner = nil
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  # ----- Initial workflow ----------------------------------------

  describe "Initial workflow (issue → PR)" do
    it "runs implement → summarize → pr_open end-to-end, opens PR, succeeds" do
      job
      drain_workflow!(job)

      job.reload
      wf = job.workflows.first
      expect(wf.trigger_kind).to eq("initial")
      expect(wf.state).to eq("succeeded")
      expect(wf.steps.pluck(:kind, :state)).to eq([
        [ "prepare",   "succeeded" ],
        [ "implement", "succeeded" ],
        [ "grade",     "succeeded" ],
        [ "summarize", "succeeded" ],
        [ "pr_open",   "succeeded" ]
      ])
      expect(wf.artifact("pr_title")).to eq("Add greeting helper")
      expect(job.pr_number).to eq(123)
      expect(job.branch_name).to eq("syrus/issue-42-#{job.id}")
      expect(@pr_stub).to have_been_requested

      branches = `git --git-dir=#{bare_remote_dir} branch --list 'syrus/*'`.split("\n").map(&:strip)
      expect(branches).to include(job.branch_name)
    end

    it "loops implement + grade until graders pass, then opens the PR" do
      AppSetting.current.update!(grade_max_iterations: 2)
      commit_file_to_remote(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: test -f grade-pass
      YAML
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        file = File.join(workspace_path, "feature.rb")
        if current.step.kind == "implement"
          File.write(file, "def greet = 'hello'\n")
          File.write(File.join(workspace_path, "grade-pass"), "ok\n") if current.iteration >= 2
        elsif current.step.kind == "summarize"
          current.update!(
            agent_pr_title: "Add greeting helper",
            agent_pr_body: "Adds a tiny greet helper used by the welcome page.",
            agent_summary: "Implemented greet."
          )
        end
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "S-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }

      job
      drain_workflow!(job)

      wf = job.workflows.last
      expect(wf.reload.state).to eq("succeeded")
      expect(wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "succeeded" ]
      ])
      expect(wf.steps.find_by(kind: "implement", iteration: 2).runs.first.parent_session_id).to eq("S-1")
      expect(job.reload.pr_number).to eq(123)
      expect(@pr_stub).to have_been_requested
    end

    it "fails with loop_exhausted when grade never passes and does not open a PR" do
      AppSetting.current.update!(grade_max_iterations: 2)
      commit_file_to_remote(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: "false"
      YAML

      job
      drain_workflow!(job)

      wf = job.workflows.last
      expect(wf.reload.state).to eq("failed")
      expect(wf.artifact("failure_reason")).to eq("loop_exhausted")
      expect(wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "failed" ]
      ])
      expect(wf.steps.where(kind: "pr_open").first.runs).to be_empty
      expect(@pr_stub).not_to have_been_requested
    end

    it "rewrites implement's placeholder commit message via summarize's `git commit --amend`" do
      job; drain_workflow!(job)
      tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{job.branch_name}`.strip
      expect(tip).to eq("Add greeting helper")
    end

    it "includes the agent pr_body in the commit message body" do
      job; drain_workflow!(job)
      body = `git --git-dir=#{bare_remote_dir} log -1 --format='%b' #{job.branch_name}`.strip
      expect(body).to include("Adds a tiny greet helper used by the welcome page.")
    end

    it "prepends Closes #N in the commit message for issue jobs" do
      job; drain_workflow!(job)
      full = `git --git-dir=#{bare_remote_dir} log -1 --format='%B' #{job.branch_name}`.strip
      expect(full).to include("Closes #42")
    end

    it "authors commits as the User in PAT mode" do
      job; drain_workflow!(job)

      author = `git --git-dir=#{bare_remote_dir} log -1 --format='%an <%ae>' #{job.branch_name}`.strip

      expect(author).to eq("Ada Lovelace <ada@example.com>")
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

    it "adds a Co-Authored-By trailer for issue-triggered jobs" do
      job; drain_workflow!(job)
      full = `git --git-dir=#{bare_remote_dir} log -1 --format='%B' #{job.branch_name}`.strip

      expect(full).to include("Co-Authored-By: Ada Lovelace <ada@example.com>")
    end

    it "tears down the workspace when the Workflow succeeds" do
      job; drain_workflow!(job)
      wf = job.workflows.last
      expect(WorkflowWorkspace.path_for(wf)).not_to exist
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

    it "stamps issue_title + issue_body on the Job" do
      job; drain_workflow!(job)
      job.reload
      expect(job.issue_title).to eq("Add greeting helper")
      expect(job.issue_body).to eq("We need a greeting helper.")
    end

    it "schedules a delayed PollRebaseJob so the mergeability badge refreshes after pr_open" do
      # We can't easily assert have_enqueued_job because drain
      # consumes the queue. Instead spy on the API call.
      expect(PollRebaseJob).to receive(:set).with(hash_including(:wait)).and_return(double(perform_later: true))
      job; drain_workflow!(job)
    end

    it "adds human trigger attribution to ad hoc PR descriptions" do
      adhoc = user.jobs.create!(
        repository: repository,
        kind: "adhoc",
        issue_title: "Manual tidy",
        issue_body: "Clean up the docs."
      )
      workflow = Workflows::Initial.instantiate(job: adhoc, agent_provider: adhoc.agent_provider)
      StepDispatcher.start_workflow(workflow, prompt: Prompts::AdhocJob.new(prompt: adhoc.issue_body).to_s)

      drain_workflow!(adhoc)

      expect(a_request(:post, "https://api.github.com/repos/acme/widgets/pulls").with(
        body: hash_including("body" => including("Triggered by @ada"))
      )).to have_been_made
    end
  end

  # ----- Resume Workflow -----------------------------------------

  describe "Resume workflow (continuation via --resume)" do
    it "creates a manual-step Run carrying parent_session_id so AgentInvocation passes --resume" do
      wf = Workflows::Resume.instantiate(job: job)
      StepDispatcher.start_workflow(wf, parent_session_id: "S-prior")

      run = wf.first_step.runs.first
      expect(run.parent_session_id).to eq("S-prior")
      # Mark prompt so Steps::Manual's "manual step requires a prompt"
      # guard doesn't fire — Resume normally inherits a prompt from
      # Prompts::Resume composed elsewhere.
      run.update!(prompt: "Continue from where you left off")

      RunJob.perform_now(run.id)
      expect(run.reload.state).to eq("succeeded")
      expect(wf.reload.state).to eq("succeeded")
    end
  end

  # ----- PrFeedback workflow -------------------------------------

  describe "PrFeedback workflow (pr_comment → respond → grade → summarize_amend → push)" do
    before do
      # Initial workflow first so the branch exists on origin.
      job; drain_workflow!(job)
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
      expect(wf.steps.pluck(:kind, :state)).to eq([
        [ "prepare",         "succeeded" ],
        [ "respond",         "succeeded" ],
        [ "grade",           "succeeded" ],
        [ "summarize_amend", "succeeded" ],
        [ "push",            "succeeded" ]
      ])
      # No new PR — same Job's existing one
      expect(@pr_stub).not_to have_been_requested
      # Branch on origin should now have one extra commit
      log = `git --git-dir=#{bare_remote_dir} log --oneline #{job.branch_name}`.split("\n")
      expect(log.size).to be >= 2
    end

    it "loops respond + grade until graders pass, then summarizes and pushes" do
      AppSetting.current.update!(grade_max_iterations: 2)
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        case current.step.kind
        when "respond"
          File.write(File.join(workspace_path, ".syrus.yml"), <<~YAML)
            grade:
              - name: tests
                run: test -f grade-pass
          YAML
          File.open(File.join(workspace_path, "feature.rb"), "a") { |f| f.puts "# addressed feedback iteration #{current.iteration}" }
          File.write(File.join(workspace_path, "grade-pass"), "ok\n") if current.iteration >= 2
        when "summarize_amend"
          current.update!(
            agent_pr_title: "Address review feedback",
            agent_pr_body: "Tightens the review-requested behavior.",
            agent_summary: "Addressed feedback."
          )
        end
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "R-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }
      wf = Workflows::PrFeedback.instantiate(
        job: job,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "tighten the docstring", "created_at" => Time.current.iso8601 } ] }
      )
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)

      expect(wf.reload.state).to eq("succeeded")
      expect(wf.steps.where(kind: "respond").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "succeeded" ]
      ])
      expect(wf.steps.find_by(kind: "respond", iteration: 2).runs.first.parent_session_id).to eq("R-1")
      expect(wf.steps.find_by(kind: "summarize_amend").runs.first).to be_succeeded
      expect(wf.steps.find_by(kind: "push").runs.first).to be_succeeded
    end

    it "fails with loop_exhausted when review feedback grading never passes" do
      AppSetting.current.update!(grade_max_iterations: 2)
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        if current.step.kind == "respond"
          File.write(File.join(workspace_path, ".syrus.yml"), <<~YAML)
            grade:
              - name: tests
                run: "false"
          YAML
          File.open(File.join(workspace_path, "feature.rb"), "a") { |f| f.puts "# attempted feedback iteration #{current.iteration}" }
        end
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "R-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }
      wf = Workflows::PrFeedback.instantiate(
        job: job,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "tighten the docstring", "created_at" => Time.current.iso8601 } ] }
      )
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)

      expect(wf.reload.state).to eq("failed")
      expect(wf.artifact("failure_reason")).to eq("loop_exhausted")
      expect(wf.steps.where(kind: "respond").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "failed" ]
      ])
      expect(wf.steps.where(kind: "push").first.runs).to be_empty
    end
  end

  # ----- Retry workflow ------------------------------------------

  describe "Retry workflow (retry → implement → grade → summarize → pr_open)" do
    before do
      # Initial workflow first so retry reuses a real existing branch.
      job; drain_workflow!(job)
      WebMock.reset_executed_requests!
    end

    it "loops implement + grade until graders pass, then summarizes and reaches pr_open" do
      AppSetting.current.update!(grade_max_iterations: 2)
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        case current.step.kind
        when "implement"
          File.write(File.join(workspace_path, ".syrus.yml"), <<~YAML)
            grade:
              - name: tests
                run: test -f grade-pass
          YAML
          File.write(File.join(workspace_path, "retry_feature.rb"), "def retry_iteration = #{current.iteration}\n")
          File.write(File.join(workspace_path, "grade-pass"), "ok\n") if current.iteration >= 2
        when "summarize"
          current.update!(
            agent_pr_title: "Retry greeting helper",
            agent_pr_body: "Retries the greeting helper implementation.",
            agent_summary: "Retried implementation."
          )
        end
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "I-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }
      wf = Workflows::Retry.instantiate(job: job)
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)

      expect(wf.reload.state).to eq("succeeded")
      expect(wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "succeeded" ]
      ])
      expect(wf.steps.find_by(kind: "implement", iteration: 2).runs.first.parent_session_id).to eq("I-1")
      expect(wf.steps.find_by(kind: "summarize").runs.first).to be_succeeded
      expect(wf.steps.find_by(kind: "pr_open").runs.first).to be_succeeded
    end

    it "fails with loop_exhausted when retry grading never passes" do
      AppSetting.current.update!(grade_max_iterations: 2)
      RunJob.agent_runner = ->(workspace_path:, **_) {
        current = Run.last
        if current.step.kind == "implement"
          File.write(File.join(workspace_path, ".syrus.yml"), <<~YAML)
            grade:
              - name: tests
                run: "false"
          YAML
          File.write(File.join(workspace_path, "retry_feature.rb"), "def retry_iteration = #{current.iteration}\n")
        end
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: nil, session_id: "I-#{current.iteration}",
                                    transcript_jsonl: "{}\n")
      }
      wf = Workflows::Retry.instantiate(job: job)
      StepDispatcher.start_workflow(wf)

      drain_workflow!(job)

      expect(wf.reload.state).to eq("failed")
      expect(wf.artifact("failure_reason")).to eq("loop_exhausted")
      expect(wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])
      expect(wf.steps.where(kind: "grade").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ],
        [ 2, "failed" ]
      ])
      expect(wf.steps.where(kind: "pr_open").first.runs).to be_empty
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

    it "no-changes path: agent surveys, finds nothing → Run fails (implement step), Workflow + Job fail" do
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
    it "Run + Step + Workflow fail; no PR opened" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      job; drain_workflow!(job)

      expect(job.workflows.last.state).to eq("failed")
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
      expect(job.reload.state).to eq("open")
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
    when "implement", "manual"
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
    when "agent_rebase"
      sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
    end
    AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
  end

  def default_pr_summarizer_runner(**_)
    AgentInvocation::Result.new(
      turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success",
      final_text: '{"title":"Summarizer fallback","body":"Summarizer fallback body."}',
      session_id: nil
    )
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

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "seed@example.com",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "seed@example.com" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
