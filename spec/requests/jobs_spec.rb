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

      it "shows Summary and Workflows tabs when a run has an agent_summary" do
        run = job.initial_run
        run.start!; run.succeed!; run.save!
        run.update!(agent_summary: "Added the greeting helper method to ApplicationHelper.")

        get job_path(job)
        expect(response.body).to include("Summary")
        expect(response.body).to include("Workflows (")
        expect(response.body).to include("Added the greeting helper method to ApplicationHelper.")
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

      it "does not show Summary tab when no run has an agent_summary" do
        run = job.initial_run
        run.start!; run.succeed!; run.save!

        get job_path(job)
        # No summary tab nav — the runs render directly without tabs.
        expect(response.body).not_to include('data-action="click-&gt;tabs#switch"')
      end

      it "404s for another user's job" do
        foreign_repo = Factories.repository(user: other)
        foreign_job = Factories.job(repository: foreign_repo, issue_number: 1)
        get job_path(foreign_job)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /jobs/:id/run_again (soft replay)" do
    before { sign_in_as(user) }

    it "creates a new Run with trigger_kind=replay on the existing Job and enqueues RunJob" do
      job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      expect {
        post run_again_job_path(job)
      }.to change { job.runs.count }.by(1)
        .and have_enqueued_job(RunJob)

      new_run = job.runs.last
      expect(new_run.trigger_kind).to eq("replay")
      expect(new_run.state).to eq("queued")
      expect(response).to redirect_to(job_path(job))
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
end
