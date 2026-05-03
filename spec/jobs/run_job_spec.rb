require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RunJob do
  # Build a real bare git repo on the local filesystem to play the role of
  # github.com — push lands here, exercising the full clone/branch/commit/push
  # plumbing without leaving the box. Octokit's create_pull_request and
  # fetch_issue are intercepted with WebMock; the agent runner is stubbed so
  # we don't shell out to claude in tests.
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-bare")) }
  let(:user) { Factories.user(github_token: "ghp_test_token", claude_oauth_token: "oat-test") }
  let(:repository) do
    Factories.repository(
      user: user, owner: "acme", name: "widgets",
      default_branch: "main", trigger_label: "syrus", polling_enabled: true
    )
  end
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:run) { job.initial_run }

  before do
    seed_remote_with_initial_commit(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")

    stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { number: 42, title: "Add greeting helper", body: "We need a greeting helper.", state: "open" }.to_json
    )

    @pr_stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls").to_return(
      status: 201,
      headers: { "Content-Type" => "application/json" },
      body: { number: 123, html_url: "https://github.com/acme/widgets/pull/123" }.to_json
    )

    # Default agent_runner: writes a diff *and* simulates the agent
    # calling `submit_summary` via the MCP sidecar (which under
    # normal operation persists onto Run). This is the realistic
    # happy path now — RunJob reads these fields when opening the PR.
    RunJob.agent_runner = ->(workspace_path:, **_) {
      File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
      Run.last.update!(
        agent_pr_title: "Add greeting helper",
        agent_pr_body:  "Adds a tiny greet helper used by the welcome page.",
        agent_summary:  "Implemented greet."
      )
      AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
    }

    # Default summarizer stub: returns valid JSON so the fallback
    # path also works when a test overrides the agent_runner to
    # *not* call submit_summary.
    PrSummarizer.runner = ->(**_) {
      AgentInvocation::Result.new(
        turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success",
        final_text: '{"title":"Summarizer fallback title","body":"Summarizer fallback body."}',
        session_id: nil
      )
    }

    @syrus_data_root = Dir.mktmpdir("syrus-test-data")
    ENV["SYRUS_DATA_ROOT"] = @syrus_data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    RunJob.agent_runner = nil
    PrSummarizer.runner = nil
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@syrus_data_root) if @syrus_data_root
  end

  describe "happy path (initial run)" do
    it "runs the agent, commits, pushes, opens PR, succeeds — Run holds the metadata, Job holds the thread" do
      described_class.perform_now(run.id)

      run.reload
      job.reload

      expect(run.state).to eq("succeeded")
      expect(run.agent_turns).to eq(4)
      expect(run.agent_outcome).to eq("success")
      expect(run.agent_diff).to include("feature.rb").and include("def greet")
      expect(run.head_sha).to be_present
      expect(run.prompt).to include("Add greeting helper")

      expect(job.state).to eq("open")     # thread stays open even after a successful run
      expect(job.branch_name).to eq("syrus/issue-42-#{job.id}")
      expect(job.pr_number).to eq(123)
      expect(job.issue_title).to eq("Add greeting helper")
      expect(job.issue_body).to eq("We need a greeting helper.")
      expect(@pr_stub).to have_been_requested

      branches = `git --git-dir=#{bare_remote_dir} branch --list 'syrus/*'`.split("\n").map(&:strip)
      expect(branches).to include(job.branch_name)

      files = `git --git-dir=#{bare_remote_dir} ls-tree --name-only #{job.branch_name}`.split("\n")
      expect(files).to include("feature.rb")

      tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{job.branch_name}`.strip
      expect(tip).to eq("Add greeting helper")
    end

    it "tears down the worktree" do
      described_class.perform_now(run.id)
      expect(JobWorkspace.data_root.join("worktrees", run.id.to_s)).not_to exist
    end

    it "schedules a delayed PollRebaseJob so the mergeability badge refreshes after the push" do
      expect {
        described_class.perform_now(run.id)
      }.to have_enqueued_job(PollRebaseJob).with(job.id)
    end

    it "captures the Claude session JSONL when the agent reports a session_id" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        # Simulate claude writing its JSONL to the canonical path.
        path = ClaudeSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: workspace_path, session_id: "smoke-uuid")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, %({"type":"meta","sessionId":"smoke-uuid"}\n))
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
        Run.last.update!(agent_pr_title: "x", agent_pr_body: "y", agent_summary: "z")
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: "smoke-uuid")
      }

      expect {
        described_class.perform_now(run.id)
      }.to change { ClaudeSession.count }.by(1)

      session = ClaudeSession.find_by(session_id: "smoke-uuid")
      expect(session.run_id).to eq(run.id)
      expect(session.transcript_jsonl).to include("smoke-uuid")
    end

    it "doesn't fail the Run when the JSONL file isn't on disk" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
        Run.last.update!(agent_pr_title: "x", agent_pr_body: "y", agent_summary: "z")
        # session_id reported but no file on disk
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: "ghost-uuid")
      }

      expect { described_class.perform_now(run.id) }.not_to raise_error
      expect(run.reload.state).to eq("succeeded")
      expect(ClaudeSession.exists?(session_id: "ghost-uuid")).to be false
    end

    it "opens the PR with the title/body the agent submitted via the MCP sidecar (path 1)" do
      described_class.perform_now(run.id)

      expect(WebMock).to have_requested(:post, "https://api.github.com/repos/acme/widgets/pulls").with { |req|
        body = JSON.parse(req.body)
        body["title"] == "Add greeting helper" &&
          body["body"].start_with?("Closes #42") &&
          body["body"].include?("Adds a tiny greet helper")
      }
      expect(run.reload).to have_attributes(
        agent_pr_title: "Add greeting helper",
        agent_summary:  "Implemented greet."
      )
    end

    it "falls back to PrSummarizer when the agent didn't call submit_summary (path 2)" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
        # NOTE: deliberately skipping the Run.update! that would simulate
        # submit_summary — pretending the agent forgot the tool call.
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      described_class.perform_now(run.id)

      expect(WebMock).to have_requested(:post, "https://api.github.com/repos/acme/widgets/pulls").with { |req|
        body = JSON.parse(req.body)
        body["title"] == "Summarizer fallback title" &&
          body["body"].start_with?("Closes #42") &&
          body["body"].include?("Summarizer fallback body")
      }
      expect(run.reload.agent_pr_title).to be_nil
    end

    it "falls back to the templated title/body when both the agent and the summarizer fail (path 3)" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
        AgentInvocation::Result.new(turns: 4, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      PrSummarizer.runner = ->(**_) {
        AgentInvocation::Result.new(
          turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success",
          final_text: "definitely not JSON",
          session_id: nil
        )
      }

      described_class.perform_now(run.id)

      expect(WebMock).to have_requested(:post, "https://api.github.com/repos/acme/widgets/pulls").with { |req|
        body = JSON.parse(req.body)
        body["title"] == "[syrus] acme/widgets#42" && body["body"].start_with?("Closes #42")
      }
      expect(run.reload.state).to eq("succeeded")
    end

    it "passes the user's agent_max_turns through to the agent runner" do
      user.update!(agent_max_turns: 750)
      seen_max_turns = nil
      RunJob.agent_runner = ->(workspace_path:, max_turns:, **_) {
        seen_max_turns = max_turns
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi'\n")
        Run.last.update!(agent_pr_title: "x", agent_pr_body: "y", agent_summary: "z")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      described_class.perform_now(run.id)

      expect(seen_max_turns).to eq(750)
    end

    it "writes the per-run mcp.json tempfile and passes its path to AgentInvocation" do
      captured_path = nil
      captured_config = nil
      RunJob.agent_runner = ->(workspace_path:, mcp_config:, **_) {
        captured_path   = mcp_config
        captured_config = JSON.parse(File.read(mcp_config))   # read inside the Tempfile block
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi'\n")
        Run.last.update!(agent_pr_title: "x", agent_pr_body: "y", agent_summary: "z")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      described_class.perform_now(run.id)

      expect(captured_path).to be_a(String).and end_with(".json")
      sidecar = captured_config.dig("mcpServers", "syrus")
      expect(sidecar["type"]).to eq("stdio")
      expect(sidecar["command"]).to end_with("bin/syrus-mcp-sidecar")
      expect(sidecar["args"]).to eq([ "--run-id", run.id.to_s ])
    end
  end

  describe "resume Run" do
    it "restores the parent session's JSONL to the new worktree path before invoking claude" do
      # Pre-seed a captured session on a prior failed Run.
      prior_run = job.runs.create!(trigger_kind: "initial", state: "failed", started_at: 1.hour.ago, finished_at: 30.minutes.ago, prompt: "old")
      prior_session = ClaudeSession.create!(run: prior_run, session_id: "resume-uuid", transcript_jsonl: %({"type":"old","sessionId":"resume-uuid"}\n))

      restored_path = nil
      restored_contents = nil
      passed_resume_id = nil
      RunJob.agent_runner = ->(workspace_path:, resume_session_id:, **_) {
        # On invocation, the JSONL should already be at the canonical path.
        restored_path = ClaudeSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: workspace_path, session_id: "resume-uuid")
        restored_contents = File.read(restored_path) if File.exist?(restored_path)
        passed_resume_id = resume_session_id
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hello'\n")
        Run.last.update!(agent_pr_title: "x", agent_pr_body: "y", agent_summary: "z")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: "resume-uuid")
      }

      resume_run = job.runs.create!(trigger_kind: "resume", parent_session_id: prior_session.session_id)
      described_class.perform_now(resume_run.id)

      expect(passed_resume_id).to eq("resume-uuid")
      expect(restored_path).to be_present
      expect(restored_contents).to include("resume-uuid")
    end
  end

  describe "follow-up run" do
    it "pushes a new commit to the existing branch and does NOT open a second PR" do
      # Run the initial run end-to-end first.
      described_class.perform_now(run.id)
      job.reload
      expect(job.pr_number).to eq(123)
      WebMock.reset_executed_requests!

      # Now create a follow-up run.
      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi there'\n")
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      described_class.perform_now(followup.id)

      followup.reload
      job.reload
      expect(followup.state).to eq("succeeded")
      expect(followup.trigger_kind).to eq("pr_comment")
      expect(job.pr_number).to eq(123)  # unchanged — no new PR
      expect(@pr_stub).not_to have_been_requested  # no new POST /pulls

      # The branch should now have two syrus commits.
      log = `git --git-dir=#{bare_remote_dir} log --format='%s' #{job.branch_name}`.split("\n")
      expect(log.grep(/Syrus/).count).to eq(2)
    end

    it "opens the PR on a replay Run when the initial Run never reached push" do
      # Reproduces Job 10: an initial Run failed mid-agent (no commit,
      # no push, no PR), then a replay Run takes over, succeeds, and
      # MUST open the PR — otherwise the branch makes it to origin
      # with no PR pointing at it.
      job.update!(branch_name: "syrus/issue-42-#{job.id}")  # initial set this before dying
      replay = Run.create!(job: job, trigger_kind: "replay")

      expect {
        described_class.perform_now(replay.id)
      }.to change { job.reload.pr_number }.from(nil).to(123)
      expect(@pr_stub).to have_been_requested
      expect(replay.reload.state).to eq("succeeded")
    end

    it "does not open a second PR on a replay after the initial already opened one" do
      described_class.perform_now(run.id)
      expect(job.reload.pr_number).to eq(123)
      WebMock.reset_executed_requests!

      replay = Run.create!(job: job, trigger_kind: "replay")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi again'\n")
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      described_class.perform_now(replay.id)

      expect(@pr_stub).not_to have_been_requested
      expect(job.reload.pr_number).to eq(123)  # unchanged
    end

    it "captures only the branch's contribution in agent_diff, even when main moves forward" do
      # Initial run lays down feature.rb on the syrus branch.
      described_class.perform_now(run.id)
      job.reload

      # Now main moves forward with an unrelated commit. This is the
      # real-world setup that broke before: PR sat open while we
      # landed other things on main.
      Dir.mktmpdir("syrus-main-bump") do |bump|
        sh("git clone -q #{bare_remote_dir} #{bump}")
        File.write("#{bump}/UNRELATED.md", "this landed on main after the syrus PR was opened\n")
        sh("git -C #{bump} add UNRELATED.md")
        sh("git -C #{bump} commit -q -m 'unrelated main commit'")
        sh("git -C #{bump} push origin main")
      end

      # Spawn a follow-up Run that touches feature.rb.
      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi there'\n")
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      described_class.perform_now(followup.id)

      followup.reload
      expect(followup.state).to eq("succeeded")
      # The captured diff must NOT include UNRELATED.md as a removal —
      # that file is only on main, never on the syrus branch.
      expect(followup.agent_diff).not_to include("UNRELATED.md")
      expect(followup.agent_diff).to include("feature.rb")
    end

    it "uses the agent-submitted title as the commit message on a follow-up run" do
      described_class.perform_now(run.id)
      job.reload
      WebMock.reset_executed_requests!

      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi there'\n")
        Run.last.update!(
          agent_pr_title: "Address review feedback: use keyword argument",
          agent_pr_body:  "Switched from positional to keyword argument as requested.",
          agent_summary:  "Updated greet method signature."
        )
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      described_class.perform_now(followup.id)

      tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{job.branch_name}`.strip
      expect(tip).to eq("Address review feedback: use keyword argument")
    end

    it "falls back to the templated commit message when the agent didn't call submit_summary on a follow-up run" do
      described_class.perform_now(run.id)
      job.reload
      WebMock.reset_executed_requests!

      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "feature.rb"), "def greet = 'hi there'\n")
        # Deliberately not calling submit_summary — template fallback expected.
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      described_class.perform_now(followup.id)

      tip = `git --git-dir=#{bare_remote_dir} log -1 --format='%s' #{job.branch_name}`.strip
      expect(tip).to match(/Syrus pr_comment for acme\/widgets#42/)
    end
  end

  describe "rebase Run" do
    # Run an initial Run so we have a real branch on origin to rebase.
    before do
      described_class.perform_now(run.id)
      job.reload
      WebMock.reset_executed_requests!
    end

    it "force-pushes a rebased HEAD when the agent moves it" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        # Simulate a rebase by creating a new commit (changes HEAD sha)
        # without changing the working tree's diff against base.
        sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
        AgentInvocation::Result.new(turns: 3, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      rebase = Run.create!(job: job, trigger_kind: "rebase")
      expect { described_class.perform_now(rebase.id) }.not_to raise_error

      expect(rebase.reload.state).to eq("succeeded")
      # The branch on origin should have advanced: log shows >= 2
      # commits (original + rebase commit).
      log = `git --git-dir=#{bare_remote_dir} log --format='%s' #{job.branch_name}`.lines.size
      expect(log).to be >= 2
    end

    it "fails the Run when the agent doesn't move HEAD (rebase aborted or no-op)" do
      RunJob.agent_runner = ->(**_) {
        # Agent succeeded at the call but didn't actually rebase.
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      rebase = Run.create!(job: job, trigger_kind: "rebase")
      expect { described_class.perform_now(rebase.id) }.to raise_error(RunJob::AgentRunFailed, /did not move HEAD/)
      expect(rebase.reload.state).to eq("failed")
    end

    it "doesn't open a second PR" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      rebase = Run.create!(job: job, trigger_kind: "rebase")
      described_class.perform_now(rebase.id)

      expect(@pr_stub).not_to have_been_requested
      expect(job.reload.pr_number).to eq(123)  # unchanged
    end

    it "passes the user's agent_max_turns through on the rebase code path" do
      user.update!(agent_max_turns: 333)
      seen_max_turns = nil
      RunJob.agent_runner = ->(workspace_path:, max_turns:, **_) {
        seen_max_turns = max_turns
        sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      rebase = Run.create!(job: job, trigger_kind: "rebase")
      described_class.perform_now(rebase.id)
      expect(seen_max_turns).to eq(333)
    end

    it "runs even when the Job is closed (rebase is independent of Job lifecycle)" do
      job.close_with_reason!("manual")
      RunJob.agent_runner = ->(workspace_path:, **_) {
        sh("git -c user.name=t -c user.email=t@e -C #{workspace_path} commit --allow-empty -q -m 'rebased'")
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
      rebase = Run.create!(job: job, trigger_kind: "rebase")
      described_class.perform_now(rebase.id)
      expect(rebase.reload.state).to eq("succeeded")
    end
  end

  describe "cron Job (scheduled task)" do
    let(:scheduled_task) do
      ScheduledTask.create!(
        user: user, repository: repository,
        name: "Sweep dead code", prompt: "Look for dead code.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
    end

    def cron_job_with_pre_rendered_prompt(prompt: "rendered cron prompt")
      job = Job.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: scheduled_task, issue_number: nil
      )
      job.runs.create!(trigger_kind: "initial", prompt: prompt)
      job
    end

    it "happy path: agent commits, branch + PR open against the syrus/scheduled-N-M branch" do
      cron_job = cron_job_with_pre_rendered_prompt
      cron_run = cron_job.runs.first

      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "audit.md"), "found stuff\n")
        Run.last.update!(agent_pr_title: "Sweep audit", agent_pr_body: "Removed dead code.", agent_summary: "ok")
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      described_class.perform_now(cron_run.id)
      cron_job.reload
      cron_run.reload

      expect(cron_run.state).to eq("succeeded")
      expect(cron_job.branch_name).to start_with("syrus/scheduled-#{scheduled_task.id}-")
      expect(cron_job.pr_number).to eq(123)

      branches = `git --git-dir=#{bare_remote_dir} branch --list 'syrus/*'`.split("\n").map(&:strip)
      expect(branches).to include(cron_job.branch_name)
    end

    it "no-changes path: Run succeeds, Job closes with reason 'no_changes', no PR opened, ScheduledTask gets a success" do
      cron_job = cron_job_with_pre_rendered_prompt
      cron_run = cron_job.runs.first

      RunJob.agent_runner = ->(workspace_path:, **_) {
        # Agent produces NO files on disk → no diff
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      expect { described_class.perform_now(cron_run.id) }.not_to raise_error

      cron_job.reload
      cron_run.reload
      scheduled_task.reload

      expect(cron_run.state).to eq("succeeded")
      expect(cron_job.state).to eq("closed")
      expect(cron_job.closure_reason).to eq("no_changes")
      expect(cron_job.pr_number).to be_nil
      expect(@pr_stub).not_to have_been_requested
      expect(scheduled_task.last_successful_fire_at).to be_present
      expect(scheduled_task.consecutive_failure_count).to eq(0)
    end

    it "agent failure: Job's failure_count climbs; eventually closes too_many_failures and records a failure on the ScheduledTask" do
      cron_job = cron_job_with_pre_rendered_prompt
      cron_run = cron_job.runs.first

      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: true, outcome: "error_during_execution", final_text: nil, session_id: nil)
      }
      AppSetting.current.update!(max_job_failures: 1)

      expect { described_class.perform_now(cron_run.id) }.to raise_error(RunJob::AgentRunFailed)

      cron_job.reload
      scheduled_task.reload
      expect(cron_job.state).to eq("closed")
      expect(cron_job.closure_reason).to eq("too_many_failures")
      expect(scheduled_task.consecutive_failure_count).to eq(1)
    end
  end

  describe "pre-pickup cancellation" do
    it "returns early when the Run was cancelled before pickup" do
      run.cancel!
      run.save!
      expect { described_class.perform_now(run.id) }.not_to raise_error
      expect(run.reload.state).to eq("cancelled")
      expect(@pr_stub).not_to have_been_requested
    end

    it "returns early when the Job was closed before pickup" do
      job.close_with_reason!("manual")
      expect { described_class.perform_now(run.id) }.not_to raise_error
      expect(@pr_stub).not_to have_been_requested
    end
  end

  describe "agent produced no changes" do
    it "marks the Run failed; Job stays open (replay possible)" do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      expect { described_class.perform_now(run.id) }.to raise_error(RunJob::AgentRunFailed, /no changes/)

      run.reload
      job.reload
      expect(run.state).to eq("failed")
      expect(run.agent_turns).to eq(1)
      expect(run.agent_diff).to be_nil
      expect(job.state).to eq("open")
      expect(@pr_stub).not_to have_been_requested
    end
  end

  describe "agent reported semantic error" do
    it "persists outcome on Run, marks Run failed, Job stays open" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        File.write(File.join(workspace_path, "partial.rb"), "# half-done")
        AgentInvocation::Result.new(turns: 50, exit_status: 0, timed_out: false,
                                    is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      }

      expect { described_class.perform_now(run.id) }.to raise_error(RunJob::AgentRunFailed, /error_max_turns/)

      run.reload
      expect(run.state).to eq("failed")
      expect(run.agent_turns).to eq(50)
      expect(run.agent_outcome).to eq("error_max_turns")
      expect(@pr_stub).not_to have_been_requested
    end
  end

  describe "failure counting" do
    before do
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }
    end

    it "increments job failure_count when a run fails" do
      expect { described_class.perform_now(run.id) rescue nil }.to change { job.reload.failure_count }.from(0).to(1)
    end

    it "auto-closes job with too_many_failures when threshold is reached" do
      AppSetting.current.update!(max_job_failures: 1)
      expect { described_class.perform_now(run.id) rescue nil }
        .to change { job.reload.closure_reason }.from(nil).to("too_many_failures")
    end

    it "does not increment failure_count for rebase runs" do
      rebase = Run.create!(job: job, trigger_kind: "rebase")
      RunJob.agent_runner = ->(**_) {
        AgentInvocation::Result.new(turns: 1, exit_status: 1, timed_out: false, is_error: false, outcome: nil, final_text: nil, session_id: nil)
      }
      expect { described_class.perform_now(rebase.id) rescue nil }
        .not_to change { job.reload.failure_count }
    end
  end

  describe "re-entrancy guard (worker died mid-run)" do
    it "marks the run failed with worker_died when it is already running on entry" do
      run.update_columns(state: "running", started_at: 10.minutes.ago)

      agent_invoked = false
      RunJob.agent_runner = ->(**_) {
        agent_invoked = true
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: nil, session_id: nil)
      }

      expect { described_class.perform_now(run.id) }.not_to raise_error

      run.reload
      expect(run.state).to eq("failed")
      expect(run.agent_outcome).to eq("worker_died")
      expect(agent_invoked).to be false
      expect(@pr_stub).not_to have_been_requested
    end

    it "writes an abandonment log entry" do
      run.update_columns(state: "running", started_at: 10.minutes.ago)
      described_class.perform_now(run.id)
      expect(run.job_logs.last.chunk).to include("worker died")
    end

    it "does not touch a run that is already terminal" do
      run.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
      described_class.perform_now(run.id)
      expect(run.reload.state).to eq("failed")
    end
  end

  describe "PR-opening failure" do
    it "marks the Run failed and cleans up the worktree" do
      stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls")
        .to_return(status: 422, body: { message: "Validation Failed" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect { described_class.perform_now(run.id) }.to raise_error(Octokit::UnprocessableEntity)

      run.reload
      expect(run.state).to eq("failed")
      expect(JobWorkspace.data_root.join("worktrees", run.id.to_s)).not_to exist
    end
  end

  def seed_remote_with_initial_commit(bare_path)
    Dir.mktmpdir("syrus-seed") do |seed|
      sh("git init -q -b main #{seed}")
      sh("git -C #{seed} commit --allow-empty -q -m 'initial' --author='Seed <seed@example.com>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3({ "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "seed@example.com",
                                        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "seed@example.com" }, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
