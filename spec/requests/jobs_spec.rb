require "rails_helper"

RSpec.describe "Jobs", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  describe "GET /jobs/:id" do
    it "requires authentication" do
      get job_path(job)
      expect(response).to redirect_to(new_session_path)
    end

    context "signed in" do
      before { sign_in_as(user) }

      it "shows the job thread + each Run with its transcript and diff" do
        run = job.initial_run
        # Bring the Step out of `queued` too — otherwise the new
        # _step partial hides the transcript collapsible (queued
        # steps haven't started, so there's nothing to show).
        run.step.start!; run.step.save!
        run.start!; run.succeed!
        run.step.succeed!; run.step.save!
        run.update!(agent_diff: "diff --git a/foo b/foo\n+bar", agent_turns: 3, agent_outcome: "success")
        JobLog.create!(run: run, sequence: 0, chunk: "hello transcript")

        get job_path(job)
        expect(response).to be_successful
        expect(response.body).to include("acme/widgets")
        expect(response.body).to include("#42")
        expect(response.body).to include("hello transcript")
        expect(response.body).to include("diff --git")
        expect(response.body).to include("initial")  # trigger pill
      end

      it "renders issue_title next to the issue number in the heading" do
        job.update!(issue_title: "Add greeting helper")
        get job_path(job)
        expect(response.body).to include("#42")
        expect(response.body).to include("Add greeting helper")
        # Both should appear close together — the title follows the issue link in the h1.
        expect(response.body).to match(/#42.*Add greeting helper/m)
      end

      it "renders issue_body when present (no summary → plain block)" do
        job.update!(issue_title: "Add greeting helper", issue_body: "We need a greeting helper.")
        get job_path(job)
        expect(response.body).to include("Add greeting helper")
        expect(response.body).to include("We need a greeting helper.")
      end

      it "renders nothing for issue body when issue_body is nil" do
        job.update!(issue_title: nil, issue_body: nil)
        get job_path(job)
        expect(response.body).not_to include("whitespace-pre-wrap")
      end

      it "shows Summary, Workflows, and Source tabs on every job page" do
        get job_path(job)
        expect(response.body).to include("Summary")
        expect(response.body).to include("Workflows (")
        expect(response.body).to include("Source")
        expect(response.body).to include('data-controller="tabs"')
      end

      it "shows agent_summary inside the Summary tab when a run has one" do
        run = job.initial_run
        run.start!; run.succeed!; run.save!
        run.update!(agent_summary: "Added the greeting helper method to ApplicationHelper.")

        get job_path(job)
        expect(response.body).to include("Summary")
        expect(response.body).to include("Workflows (")
        expect(response.body).to include("Added the greeting helper method to ApplicationHelper.")
      end

      it "shows 'No summary yet' in the Summary tab when no agent_summary and no issue_body" do
        run = job.initial_run
        run.start!; run.succeed!; run.save!

        get job_path(job)
        expect(response.body).to include("No summary yet")
      end

      it "shows issue_body inside the Summary tab when summary is present" do
        job.update!(issue_body: "We need a greeting helper.")
        run = job.initial_run
        run.start!; run.succeed!; run.save!
        run.update!(agent_summary: "Done.")

        get job_path(job)
        expect(response.body).to include("We need a greeting helper.")
        expect(response.body).to include("Done.")
      end

      it "includes a lazy Turbo Frame pointing to the source path" do
        get job_path(job)
        expect(response.body).to include('source-browser-')
        expect(response.body).to include(source_job_path(job))
        expect(response.body).to include('loading="lazy"')
      end

      it "404s for another user's job" do
        foreign_repo = Factories.repository(user: other)
        foreign_job = Factories.job(repository: foreign_repo, issue_number: 1)
        get job_path(foreign_job)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /jobs/:id/run_again (soft retry)" do
    before { sign_in_as(user) }

    it "creates a new Run with trigger_kind=retry on the existing Job and enqueues RunJob" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      expect {
        post run_again_job_path(job)
      }.to change { job.runs.count }.by(1)
        .and have_enqueued_job(RunJob)

      new_run = job.runs.last
      expect(new_run.trigger_kind).to eq("retry")
      expect(new_run.state).to eq("queued")
      expect(response).to redirect_to(job_path(job, tab: "workflows"))
    end

    it "stores replay_context in workflow artifacts when provided" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      post run_again_job_path(job), params: { replay_context: "Please fix the failing tests in spec/models/user_spec.rb." }

      workflow = job.workflows.where(trigger_kind: "replay").last
      expect(workflow.artifacts["replay_context"]).to eq("Please fix the failing tests in spec/models/user_spec.rb.")
    end

    it "stores no artifacts when replay_context is blank" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      post run_again_job_path(job), params: { replay_context: "  " }

      workflow = job.workflows.where(trigger_kind: "replay").last
      expect(workflow.artifacts).to be_nil
    end

    it "refuses when the Job is closed" do
      job.close_with_reason!("manual")
      expect {
        post run_again_job_path(job)
      }.not_to change { job.runs.count }
      expect(flash[:alert]).to match(/use Start over/)
    end

    it "refuses when an active Run is already in progress" do
      job.initial_run  # queued by default
      expect {
        post run_again_job_path(job)
      }.not_to change { job.runs.count }
      expect(flash[:alert]).to match(/already in progress/)
    end
  end

  describe "POST /jobs/:id/restart (hard reset)" do
    before { sign_in_as(user) }

    it "closes the existing Job and creates a new one with a fresh initial Run" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      original_id = job.id

      expect {
        post restart_job_path(job)
      }.to change(Job, :count).by(1)
        .and have_enqueued_job(RunJob)

      job.reload
      expect(job.state).to eq("closed")
      expect(job.closure_reason).to eq("replaced")

      new_job = Job.where(repository_id: repository.id, issue_number: 42).order(:created_at).last
      expect(new_job.id).not_to eq(original_id)
      expect(new_job.runs.first.trigger_kind).to eq("initial")
      expect(response).to redirect_to(job_path(new_job))
    end

    it "cancels active runs on the original before creating the new one" do
      job.initial_run  # queued
      post restart_job_path(job)
      expect(job.runs.first.reload.state).to eq("cancelled")
    end

    it "still creates a new Job when the original is already closed" do
      job.close_with_reason!("manual")
      expect {
        post restart_job_path(job)
      }.to change(Job, :count).by(1)
    end
  end

  describe "POST /jobs/:id/cancel" do
    before { sign_in_as(user) }

    it "cancels active runs and closes the Job thread" do
      run = job.initial_run
      run.start!; run.save!

      post cancel_job_path(job)

      job.reload
      run.reload
      expect(run.state).to eq("cancelled")
      expect(job.state).to eq("closed")
      expect(job.closure_reason).to eq("cancelled")
      expect(response).to redirect_to(job_path(job))
    end

    it "refuses to cancel an already-closed Job" do
      job.close_with_reason!("manual")
      post cancel_job_path(job)
      expect(flash[:alert]).to match(/already closed/)
    end
  end

  describe "POST /jobs/:id/stop_run" do
    before { sign_in_as(user) }

    it "cancels the target Run without closing the Job" do
      run = job.initial_run
      run.start!; run.save!

      post stop_run_job_path(job, run_id: run.id)

      run.reload
      job.reload
      expect(run.state).to eq("cancelled")
      expect(job.state).to eq("open")
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/stopped/i)
    end

    it "works on a queued (not yet started) Run" do
      run = job.initial_run  # state=queued by default

      post stop_run_job_path(job, run_id: run.id)

      expect(run.reload.state).to eq("cancelled")
      expect(job.reload.state).to eq("open")
    end

    it "refuses to stop an already-terminal Run" do
      run = job.initial_run
      run.start!; run.succeed!; run.save!

      post stop_run_job_path(job, run_id: run.id)

      expect(run.reload.state).to eq("succeeded")
      expect(flash[:alert]).to match(/not active/i)
    end

    it "returns not found for a run_id that doesn't belong to this Job" do
      other_job = Factories.job(repository: repository, issue_number: 99)
      stranger = other_job.initial_run

      post stop_run_job_path(job, run_id: stranger.id)

      expect(stranger.reload.state).to eq("queued")
      expect(flash[:alert]).to match(/not found/i)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job  = Factories.job(repository: foreign_repo, issue_number: 1)
      run          = foreign_job.initial_run

      post stop_run_job_path(foreign_job, run_id: run.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /jobs/:id/retry_step" do
    before { sign_in_as(user) }

    let(:workflow) { job.workflows.last }
    let(:failed_step) {
      workflow.steps.find_by(kind: "summarize").tap do |s|
        # Create a failed Run on the step + transition both to failed.
        run = s.runs.create!(job: job, trigger_kind: "initial",
                             state: "failed", started_at: 1.minute.ago,
                             finished_at: Time.current,
                             agent_outcome: "error_max_turns")
        s.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      end
    }

    before do
      # Bring the workflow into a failed state with the second step
      # failed. Bypass AASM (state already includes "failed" terminal).
      workflow.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      failed_step
    end

    it "reopens the Workflow + Step and creates a fresh Run on the failed step" do
      expect {
        post retry_step_job_path(job, workflow_id: workflow.id)
      }.to change { failed_step.runs.count }.by(1)

      expect(workflow.reload.state).to eq("running")
      expect(failed_step.reload.state).to eq("queued")
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/Retrying summarize/)
    end

    it "refuses when the workflow's workspace was already cleaned up" do
      workflow.update_columns(cleaned_up_at: Time.current)
      expect {
        post retry_step_job_path(job, workflow_id: workflow.id)
      }.not_to change(Run, :count)
      expect(flash[:alert]).to match(/already cleaned up/i)
    end

    it "refuses when the workflow isn't failed" do
      workflow.update!(state: "running", finished_at: nil)
      post retry_step_job_path(job, workflow_id: workflow.id)
      expect(flash[:alert]).to match(/not in a failed state/i)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job  = Factories.job(repository: foreign_repo, issue_number: 1)
      foreign_wf   = foreign_job.workflows.last
      post retry_step_job_path(foreign_job, workflow_id: foreign_wf.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /jobs/:id/poll_feedback" do
    before { sign_in_as(user) }

    it "enqueues PollPullRequestJob for an open Job with a PR" do
      job.update!(pr_number: 42)
      expect {
        post poll_feedback_job_path(job)
      }.to have_enqueued_job(PollPullRequestJob).with(job.id)
      expect(response).to redirect_to(job_path(job))
    end

    it "refuses on a Job with no PR" do
      expect {
        post poll_feedback_job_path(job)
      }.not_to have_enqueued_job(PollPullRequestJob)
      expect(flash[:alert]).to match(/PR/)
    end

    it "refuses on a closed Job" do
      job.update!(pr_number: 42)
      job.close_with_reason!("manual")
      expect {
        post poll_feedback_job_path(job)
      }.not_to have_enqueued_job(PollPullRequestJob)
    end
  end

  describe "POST /jobs/:id/reopen" do
    before { sign_in_as(user) }

    it "transitions a closed Job back to open and clears closure_reason + finished_at" do
      job.close_with_reason!("cancelled")

      post reopen_job_path(job)

      job.reload
      expect(job.state).to eq("open")
      expect(job.closure_reason).to be_nil
      expect(job.finished_at).to be_nil
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/reopened/)
    end

    it "warns when reopening a thread closed by syrus_stop" do
      job.close_with_reason!("syrus_stop")
      post reopen_job_path(job)
      expect(flash[:notice]).to match(/syrus-stop/)
    end

    it "warns when reopening a thread closed by pr_merged" do
      job.close_with_reason!("pr_merged")
      post reopen_job_path(job)
      expect(flash[:notice]).to match(/PR state/)
    end

    it "refuses on an open Job" do
      post reopen_job_path(job)
      expect(job.reload.state).to eq("open")
      expect(flash[:alert]).to match(/isn't closed/)
    end
  end

  describe "POST /jobs/:id/resume" do
    before { sign_in_as(user) }

    let(:failed_run) do
      r = job.initial_run
      r.start!; r.fail!; r.save!
      r
    end

    it "instantiates a Resume workflow carrying parent_session_id from the source's ClaudeSession" do
      ClaudeSession.create!(run: failed_run, session_id: "uuid-deadbeef", transcript_jsonl: "{}\n")

      expect {
        post resume_job_path(job, source_run_id: failed_run.id)
      }.to change { job.workflows.where(trigger_kind: "resume").count }.by(1)

      wf = job.workflows.where(trigger_kind: "resume").last
      first_run = wf.first_step.runs.first
      expect(first_run.parent_session_id).to eq("uuid-deadbeef")
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/Resume workflow enqueued/)
    end

    it "refuses when the source Run isn't failed/cancelled" do
      open_run = job.initial_run  # state=queued
      ClaudeSession.create!(run: open_run, session_id: "x", transcript_jsonl: "x")

      expect {
        post resume_job_path(job, source_run_id: open_run.id)
      }.not_to change { job.workflows.where(trigger_kind: "resume").count }
      expect(flash[:alert]).to match(/Only failed or cancelled/)
    end

    it "refuses when the source Run has no captured ClaudeSession" do
      expect {
        post resume_job_path(job, source_run_id: failed_run.id)
      }.not_to change { job.workflows.where(trigger_kind: "resume").count }
      expect(flash[:alert]).to match(/No Claude session captured/)
    end

    it "refuses when the source_run_id doesn't belong to this Job" do
      other_job = Factories.job(repository: repository, issue_number: 99)
      stranger = other_job.initial_run
      stranger.start!; stranger.fail!; stranger.save!
      ClaudeSession.create!(run: stranger, session_id: "y", transcript_jsonl: "y")

      post resume_job_path(job, source_run_id: stranger.id)
      expect(flash[:alert]).to match(/not found/)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job = Factories.job(repository: foreign_repo, issue_number: 1)
      post resume_job_path(foreign_job, source_run_id: 1)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "show page button visibility + confirmations" do
    before { sign_in_as(user) }

    it "puts a turbo_confirm on Cancel & close" do
      get job_path(job)
      expect(response.body).to match(/data-turbo-confirm=.*Cancel any running work/)
    end

    it "puts a turbo_confirm on Start over" do
      # The retry split-button is hidden while a Run is in flight,
      # so finish the initial Run first — Start over only appears
      # in the dropdown when the Job has no active Run.
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      get job_path(job)
      expect(response.body).to match(/data-turbo-confirm=.*abandons the existing branch/)
    end

    it "does NOT put a confirm on Retry (additive, not destructive)" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      get job_path(job)
      expect(response.body).to include("Retry")
      expect(response.body).not_to match(/data-turbo-confirm=.*Retry/)
    end

    it "shows Reopen on closed jobs and hides it on open ones" do
      get job_path(job)
      expect(response.body).not_to include("Reopen")

      job.close_with_reason!("cancelled")
      get job_path(job)
      expect(response.body).to include("Reopen")
    end
  end

  describe "POST /jobs/:id/rebase" do
    before { sign_in_as(user) }

    it "instantiates a Rebase Workflow when the Job has a PR and no rebase is in flight" do
      job.update!(pr_number: 7, branch_name: "syrus/issue-42-1")

      expect {
        post rebase_job_path(job)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/Rebase workflow enqueued/)
    end

    it "works on a closed (preempted) Job using external_pr_number" do
      job.update!(state: "closed", closure_reason: "preempted",
                  external_pr_number: 99, finished_at: Time.current)

      expect {
        post rebase_job_path(job)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
    end

    it "refuses when the Job has no PR at all" do
      job  # force creation + initial Run before the assertion
      expect {
        post rebase_job_path(job)
      }.not_to change(Workflow, :count)
      expect(response).to redirect_to(job_path(job))
      expect(flash[:alert]).to match(/No PR/)
    end

    it "refuses when a rebase Workflow is already in flight" do
      job.update!(pr_number: 7, branch_name: "syrus/issue-42-1")
      Workflow.create!(job: job, trigger_kind: "rebase", state: "queued")

      expect {
        post rebase_job_path(job)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
      expect(flash[:alert]).to match(/already in progress/)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job = Factories.job(repository: foreign_repo, issue_number: 1)
      foreign_job.update!(pr_number: 7)
      post rebase_job_path(foreign_job)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /jobs/:id/source" do
    before { sign_in_as(user) }

    let(:job_with_branch) {
      Factories.job(repository: repository, issue_number: 42).tap { |j|
        j.update!(branch_name: "syrus/issue-42-1")
      }
    }

    def stub_compare(ahead_commits: [])
      commits_json = ahead_commits.map { |sha|
        { sha: sha, commit: { message: "Change #{sha[0, 7]}", committer: { date: "2026-05-01T00:00:00Z" } } }
      }
      merge_base_sha = "aabbccdd1234567"
      stub_request(:get, %r{api\.github\.com/repos/acme/widgets/compare/})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            commits: commits_json,
            merge_base_commit: { sha: merge_base_sha }
          }.to_json
        )
      merge_base_sha
    end

    def stub_tree(ref)
      tree_sha = "tree#{ref[0, 8]}"
      stub_request(:get, %r{api\.github\.com/repos/acme/widgets/commits/#{ref}})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { commit: { tree: { sha: tree_sha } } }.to_json
        )
      stub_request(:get, %r{api\.github\.com/repos/acme/widgets/git/trees/#{tree_sha}})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            tree: [
              { path: "app/models/user.rb",      type: "blob", size: 512 },
              { path: "app/models/post.rb",      type: "blob", size: 256 },
              { path: "lib/tasks/setup.rake",    type: "blob", size: 128 },
              { path: "app/models",              type: "tree", size: nil }
            ],
            truncated: false
          }.to_json
        )
    end

    def stub_file_content(ref, path, content)
      encoded = Base64.encode64(content)
      stub_request(:get, %r{api\.github\.com/repos/acme/widgets/contents/#{Regexp.escape(path)}})
        .with(query: hash_including("ref" => ref))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { type: "file", content: encoded, size: content.bytesize, encoding: "base64" }.to_json
        )
    end

    it "requires authentication" do
      sign_in_as(Factories.user)  # sign in as someone else first to clear the cookie
      get source_job_path(job)
      # A different user should get 404 (scoped to current user's jobs)
      expect(response).to have_http_status(:not_found)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job  = Factories.job(repository: foreign_repo, issue_number: 1)
      get source_job_path(foreign_job)
      expect(response).to have_http_status(:not_found)
    end

    context "when the user has no GitHub token" do
      before { user.update!(github_token: nil) }

      it "renders an error message instead of crashing" do
        get source_job_path(job)
        expect(response).to be_successful
        expect(response.body).to include("GitHub token not configured")
      end
    end

    context "when the job has no branch yet" do
      it "shows the source browser at the default branch tree (no compare call)" do
        # No branch_name → controller skips compare and uses default_branch ("main") directly.
        stub_tree("main")
        user.update!(github_token: "ghp_test_token")

        get source_job_path(job)
        expect(response).to be_successful
        expect(response.body).to include("source-browser-#{job.id}")
        expect(response.body).to include("merge base")
        expect(response.body).to include("user.rb")
        expect(response.body).to include("post.rb")
      end
    end

    context "when the job has a branch with commits" do
      it "shows the commit selector and file tree" do
        commit_sha     = "deadbeef12345678"
        merge_base_sha = stub_compare(ahead_commits: [commit_sha])
        stub_tree(commit_sha)
        user.update!(github_token: "ghp_test_token")

        get source_job_path(job_with_branch)
        expect(response).to be_successful
        expect(response.body).to include("deadbeef")
        expect(response.body).to include("user.rb")
        expect(response.body).to include("setup.rake")
      end

      it "uses the ?ref param to select a specific commit" do
        commit_sha     = "deadbeef12345678"
        stub_compare(ahead_commits: [commit_sha])
        stub_tree(commit_sha)
        user.update!(github_token: "ghp_test_token")

        get source_job_path(job_with_branch, ref: commit_sha)
        expect(response).to be_successful
        expect(response.body).to include("user.rb")
      end

      it "loads and displays file content with syntax-highlight markup when ?path is given" do
        commit_sha = "deadbeef12345678"
        stub_compare(ahead_commits: [commit_sha])
        stub_tree(commit_sha)
        stub_file_content(commit_sha, "app/models/user.rb", "class User; end\n")
        user.update!(github_token: "ghp_test_token")

        get source_job_path(job_with_branch, ref: commit_sha, path: "app/models/user.rb")
        expect(response).to be_successful
        expect(response.body).to include("class User")
        expect(response.body).to include('language-ruby')
        expect(response.body).to include('source-highlight')
      end
    end
  end

  describe "POST /jobs/:id/check_mergeability" do
    before { sign_in_as(user) }

    it "enqueues PollRebaseJob with bypass_cache: true when the Job has a PR" do
      job.update!(pr_number: 7)
      expect {
        post check_mergeability_job_path(job)
      }.to have_enqueued_job(PollRebaseJob).with(job.id, bypass_cache: true)
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/Checking mergeability/)
    end

    it "works on a preempted Job using external_pr_number" do
      job.update!(state: "closed", closure_reason: "preempted",
                  external_pr_number: 99, finished_at: Time.current)
      expect {
        post check_mergeability_job_path(job)
      }.to have_enqueued_job(PollRebaseJob).with(job.id, bypass_cache: true)
    end

    it "refuses when the Job has no PR" do
      expect {
        post check_mergeability_job_path(job)
      }.not_to have_enqueued_job(PollRebaseJob)
      expect(flash[:alert]).to match(/No PR/)
    end
  end

  describe "POST /jobs/:id/push_commits" do
    before { sign_in_as(user) }

    let(:failed_workflow) do
      Workflow.create!(job: job, trigger_kind: "initial",
                       state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    end

    before { failed_workflow }  # ensure created before assertions

    it "enqueues PushPendingCommitsJob for a failed workflow with intact workspace" do
      expect {
        post push_commits_job_path(job, workflow_id: failed_workflow.id)
      }.to have_enqueued_job(PushPendingCommitsJob).with(failed_workflow.id)
      expect(response).to redirect_to(job_path(job))
      expect(flash[:notice]).to match(/Pushing commits/)
    end

    it "refuses when the workflow is not in a failed state" do
      failed_workflow.update_columns(state: "running", finished_at: nil)
      expect {
        post push_commits_job_path(job, workflow_id: failed_workflow.id)
      }.not_to have_enqueued_job(PushPendingCommitsJob)
      expect(flash[:alert]).to match(/not available/)
    end

    it "refuses when the workspace has already been cleaned up" do
      failed_workflow.update_columns(cleaned_up_at: Time.current)
      expect {
        post push_commits_job_path(job, workflow_id: failed_workflow.id)
      }.not_to have_enqueued_job(PushPendingCommitsJob)
      expect(flash[:alert]).to match(/not available/)
    end

    it "returns not found for a workflow_id that doesn't belong to this Job" do
      other_job  = Factories.job(repository: repository, issue_number: 99)
      other_wf   = Workflow.create!(job: other_job, trigger_kind: "initial",
                                    state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      expect {
        post push_commits_job_path(job, workflow_id: other_wf.id)
      }.not_to have_enqueued_job(PushPendingCommitsJob)
      expect(flash[:alert]).to match(/not found/)
    end

    it "404s for another user's job" do
      foreign_repo = Factories.repository(user: other)
      foreign_job  = Factories.job(repository: foreign_repo, issue_number: 1)
      post push_commits_job_path(foreign_job, workflow_id: failed_workflow.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "show page mergeability badge + Rebase button" do
    before { sign_in_as(user) }

    it "shows 'mergeable' when pr_mergeable is true" do
      job.update!(pr_number: 7, pr_mergeable: true, pr_mergeable_checked_at: 2.minutes.ago)
      get job_path(job)
      expect(response.body).to include("mergeable")
      expect(response.body).not_to include("Rebase now")
    end

    it "shows 'needs rebase' + Rebase button when pr_mergeable is false" do
      job.update!(pr_number: 7, pr_mergeable: false, pr_mergeable_checked_at: 1.minute.ago)
      get job_path(job)
      expect(response.body).to include("needs rebase")
      expect(response.body).to include("Rebase now")
    end

    it "shows 'checking…' when pr_mergeable is nil but a PR exists" do
      job.update!(pr_number: 7, pr_mergeable: nil)
      get job_path(job)
      expect(response.body).to include("checking…")
      expect(response.body).not_to include("Rebase now")
    end

    it "hides the Rebase button while a rebase Run is already active (avoid stacking)" do
      job.update!(pr_number: 7, pr_mergeable: false, pr_mergeable_checked_at: 1.minute.ago)
      job.runs.create!(trigger_kind: "rebase")

      get job_path(job)
      expect(response.body).to include("needs rebase")
      expect(response.body).not_to include("Rebase now")
    end

    it "renders no mergeability pill when the Job has no PR" do
      get job_path(job)
      expect(response.body).not_to include("mergeable")
      expect(response.body).not_to include("Rebase now")
    end
  end

  describe "GET /jobs/new" do
    it "requires authentication" do
      user  # ensure a user exists so auth redirects to login, not registration
      get new_job_path
      expect(response).to redirect_to(new_session_path)
    end

    context "signed in" do
      before { sign_in_as(user) }

      it "renders the new ad hoc job form with the user's active repositories" do
        repository  # ensure it exists
        get new_job_path
        expect(response).to be_successful
        expect(response.body).to include("New ad hoc job")
        expect(response.body).to include("acme/widgets")
      end

      it "pre-selects the repository when repository_id is given in params" do
        repository
        get new_job_path(repository_id: repository.id)
        expect(response.body).to include("selected")
        expect(response.body).to include(repository.id.to_s)
      end
    end
  end

  describe "POST /jobs (create ad hoc job)" do
    before { sign_in_as(user) }

    it "creates an adhoc Job, starts the workflow, and redirects to the job page" do
      repository  # ensure it exists
      expect {
        post jobs_path, params: {
          repository_id: repository.id,
          title: "Bump Ruby version",
          prompt: "Update the Ruby version in .ruby-version to 3.3.0."
        }
      }.to change(Job, :count).by(1)
        .and have_enqueued_job(RunJob)

      new_job = Job.order(:created_at).last
      expect(new_job.kind).to eq("adhoc")
      expect(new_job.issue_title).to eq("Bump Ruby version")
      expect(new_job.issue_body).to eq("Update the Ruby version in .ruby-version to 3.3.0.")
      expect(new_job.issue_number).to be_nil
      expect(new_job.repository).to eq(repository)
      expect(new_job.runs.count).to eq(1)
      expect(new_job.runs.first.trigger_kind).to eq("initial")
      expect(response).to redirect_to(job_path(new_job))
    end

    it "uses 'Ad hoc job' as the default title when none is provided" do
      post jobs_path, params: {
        repository_id: repository.id,
        prompt: "Do something."
      }
      new_job = Job.order(:created_at).last
      expect(new_job.issue_title).to eq("Ad hoc job")
    end

    it "pre-renders the prompt and sets it on the first Run" do
      post jobs_path, params: {
        repository_id: repository.id,
        prompt: "Do something useful."
      }
      run = Job.order(:created_at).last.runs.first
      expect(run.prompt).to include("Do something useful.")
    end

    it "re-renders the form with an error when the prompt is blank" do
      expect {
        post jobs_path, params: { repository_id: repository.id, prompt: "  " }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("blank")
    end

    it "re-renders the form with an error when repository_id is missing" do
      expect {
        post jobs_path, params: { repository_id: "", prompt: "Do something." }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Repository not found")
    end

    it "refuses to create a job for another user's repository" do
      foreign_repo = Factories.repository(user: other)
      expect {
        post jobs_path, params: {
          repository_id: foreign_repo.id,
          prompt: "Do something."
        }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /jobs authentication check" do
    it "requires authentication" do
      post jobs_path, params: { repository_id: repository.id, prompt: "Do something." }
      expect(response).to redirect_to(new_session_path)
    end
  end
end
