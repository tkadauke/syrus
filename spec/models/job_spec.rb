require "rails_helper"

RSpec.describe Job do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
  end

  describe "#slug" do
    it "returns the canonical Job slug" do
      job = Factories.job_record

      expect(job.slug).to eq("JOB-#{job.id}")
    end
  end

  describe "owner defaulting on create" do
    it "defaults owner_user to the creating user when none is given" do
      creator = Factories.user
      repo = Factories.repository(user: creator)

      job = Job.create!(user: creator, repository: repo, issue_number: 4242)

      expect(job.owner_user_id).to eq(creator.id)
    end

    it "keeps an explicitly assigned owner_user (e.g. Epic assignment)" do
      creator = Factories.user
      assignee = Factories.user
      repo = Factories.repository(user: creator)

      job = Job.create!(user: creator, repository: repo, issue_number: 4243, owner_user: assignee)

      expect(job.owner_user_id).to eq(assignee.id)
    end

    it "leaves Epic children unowned so ownership can follow the Epic" do
      creator = Factories.user
      repo = Factories.repository(user: creator)
      epic = Factories.epic(user: creator, repository: repo)

      job = Job.create!(user: creator, repository: repo, epic: epic, issue_number: 4244)

      expect(job.owner_user_id).to be_nil
    end
  end

  describe ".effectively_owned_by" do
    it "matches jobs owned by the user and the user's own NULL-owner jobs, not others'" do
      me = Factories.user
      other = Factories.user
      repo = Factories.repository(user: me)
      other_repo = Factories.repository(user: other)

      owned = Factories.job_record(repository: repo, issue_number: 1, owner_user: me)
      legacy_mine = Factories.job_record(repository: repo, issue_number: 2, user: me)
      legacy_mine.update_column(:owner_user_id, nil)
      legacy_theirs = Factories.job_record(repository: other_repo, issue_number: 3, user: other)
      legacy_theirs.update_column(:owner_user_id, nil)

      result = Job.effectively_owned_by(me)

      expect(result).to include(owned, legacy_mine)
      expect(result).not_to include(legacy_theirs)
    end
  end

  describe ".open_threads" do
    it "excludes closed and no-change-needed jobs" do
      open_job = Factories.job_record(state: "running", issue_number: 1)
      closed = Factories.job_record(state: "closed", issue_number: 2)
      no_change_needed = Factories.job_record(state: "no_change_needed", issue_number: 3)

      result = described_class.open_threads

      expect(result).to include(open_job)
      expect(result).not_to include(closed, no_change_needed)
    end
  end

  describe "fork base branch (fork -> upstream)" do
    let(:repo_owner) { Factories.user }
    let(:upstream) { Factories.repository(user: repo_owner, owner: "upstream-org", name: "project", default_branch: "main") }
    let(:fork_repo) do
      Factories.repository(user: repo_owner, owner: "fork-user", name: "project", default_branch: "main", upstream_repository: upstream)
    end

    it "bases a fork Job on the in-instance upstream's default branch" do
      job = Factories.job_record(repository: fork_repo)

      expect(job.base_repository).to eq(upstream)
      expect(job.base_default_branch).to eq("main")
      expect(job.effective_base_branch).to eq("main")
      expect(job.base_on_upstream_default?).to be(true)
    end

    it "does not upstream-base a non-fork Job" do
      plain = Factories.repository(user: repo_owner, owner: "solo", name: "app", default_branch: "main")
      job = Factories.job_record(repository: plain)

      expect(job.base_repository).to eq(plain)
      expect(job.base_on_upstream_default?).to be(false)
    end

    it "does not upstream-base a fork whose upstream is only an external slug (not in-instance)" do
      external = Factories.repository(user: repo_owner, owner: "fork-user", name: "ext", upstream_owner: "someone", upstream_name: "ext")
      job = Factories.job_record(repository: external)

      expect(external.fork?).to be(true)
      expect(external.fork_syncable?).to be(false)
      expect(job.base_on_upstream_default?).to be(false)
    end
  end

  describe "search indexing" do
    it "enqueues indexing when created" do
      repo = Factories.repository

      expect {
        Factories.job_record(user: repo.user, repository: repo, issue_title: "Search me")
      }.to have_enqueued_job(IndexJobSearchJob).with(kind_of(Integer)).on_queue("default")
    end

    it "enqueues indexing when updated" do
      job = Factories.job_record(issue_title: "Search me")
      clear_enqueued_jobs

      expect {
        job.update!(issue_title: "Search me again")
      }.to have_enqueued_job(IndexJobSearchJob).with(job.id).on_queue("default")
    end
  end

  describe "epic title snapshot" do
    it "stores the Epic title when assigned" do
      epic = Factories.epic(title: "Migration train")
      job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic)

      expect(job.reload.epic_title).to eq("Migration train")
    end

    it "clears the Epic title when removed from an Epic" do
      epic = Factories.epic(title: "Migration train")
      job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic)

      job.update!(epic: nil)

      expect(job.reload.epic_title).to be_nil
    end
  end

  describe "app events" do
    it "broadcasts a compact event when created" do
      repo = Factories.repository

      expect(AppUserChannel).to receive(:broadcast_to).with(
        repo.user,
        hash_including(
          "type" => "job.updated",
          "resource" => "job",
          "id" => kind_of(Integer),
          "changed" => include("job.created", "issue_number", "repository_id")
        )
      )

      Job.create!(user: repo.user, repository: repo, issue_number: 44)
    end

    it "broadcasts changed dashboard-relevant fields when updated" do
      allow(AppUserChannel).to receive(:broadcast_to)
      job = Factories.job_record(issue_title: "Repair the forum")

      expect(AppUserChannel).to receive(:broadcast_to).with(
        job.user,
        hash_including(
          "type" => "job.updated",
          "resource" => "job",
          "id" => job.id,
          "changed" => include("job.updated", "state", "issue_title")
        )
      )

      job.update!(state: "failed", issue_title: "Repair the basilica")
    end
  end

  describe "queued chat pending actions" do
    it "promotes matching queued actions when the Job becomes implemented" do
      repo = Factories.repository
      chat = ChatSession.create!(user: repo.user, repository: repo)
      job = Factories.job_record(user: repo.user, repository: repo, state: "running")
      matching = chat.pending_actions.create!(
        action: "submit_chat_feedback",
        state: "queued",
        payload: { "job_id" => job.id, "feedback" => "Please tighten this." }
      )
      other = chat.pending_actions.create!(
        action: "submit_chat_feedback",
        state: "queued",
        payload: { "job_id" => Factories.job_record(user: repo.user, repository: repo, state: "running").id, "feedback" => "Leave this waiting." }
      )
      allow(AppEvents).to receive(:broadcast)

      job.mark_implemented!

      expect(matching.reload).to be_pending
      expect(other.reload).to be_queued
      expect(AppEvents).to have_received(:broadcast).with(
        hash_including(
          user: repo.user,
          resource: "chat",
          id: chat.id,
          changed: [ "pending_action_updated" ],
          payload: hash_including(action: "pending_action_updated", pending_action_id: matching.id, state: "pending")
        )
      )
    end

    it "cancels matching queued actions when the Job closes" do
      repo = Factories.repository
      chat = ChatSession.create!(user: repo.user, repository: repo)
      job = Factories.job_record(user: repo.user, repository: repo, state: "running")
      matching = chat.pending_actions.create!(
        action: "submit_chat_feedback",
        state: "queued",
        payload: { "job_id" => job.id, "feedback" => "Please tighten this." }
      )
      other = chat.pending_actions.create!(
        action: "submit_chat_feedback",
        state: "queued",
        payload: { "job_id" => Factories.job_record(user: repo.user, repository: repo, state: "running").id, "feedback" => "Leave this waiting." }
      )

      job.close!

      expect(matching.reload).to be_cancelled
      expect(other.reload).to be_queued
    end
  end

  describe ".with_latest_workflow_snapshot" do
    it "selects the newest workflow metadata without requiring a workflow row" do
      job_without_workflow = Factories.job_record(issue_number: 1, issue_title: "Survey the forum")
      job_with_workflows = Factories.job_record(repository: job_without_workflow.repository, issue_number: 2, issue_title: "Pave the road")
      older_workflow = Workflow.create!(
        job: job_with_workflows,
        trigger_kind: "initial",
        state: "failed",
        created_at: 2.hours.ago
      )
      latest_workflow = Workflow.create!(
        job: job_with_workflows,
        trigger_kind: "rebase",
        state: "running",
        created_at: 1.hour.ago
      )

      rows = described_class.where(id: [ job_without_workflow.id, job_with_workflows.id ])
                            .with_latest_workflow_snapshot
                            .index_by(&:id)

      expect(rows.fetch(job_without_workflow.id).latest_workflow_id).to be_nil
      expect(rows.fetch(job_without_workflow.id).latest_workflow_state).to eq("queued")
      expect(rows.fetch(job_without_workflow.id).latest_workflow_trigger_kind).to be_nil
      expect(rows.fetch(job_without_workflow.id).latest_workflow_created_at).to be_nil

      row = rows.fetch(job_with_workflows.id)
      expect(row.latest_workflow_id).to eq(latest_workflow.id)
      expect(row.latest_workflow_id).not_to eq(older_workflow.id)
      expect(row.latest_workflow_state).to eq("running")
      expect(row.latest_workflow_trigger_kind).to eq("rebase")
      expect(row.latest_workflow_created_at.to_i).to eq(latest_workflow.created_at.to_i)
    end

    it "prefers the most recently finished workflow over the most recently created one" do
      job = Factories.job_record(issue_number: 1, issue_title: "Resurface the forum")
      # WF-B was created more recently but finished (failed) earlier
      wf_b = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "failed",
        created_at: 1.hour.ago,
        finished_at: 30.minutes.ago
      )
      # WF-A was created earlier but resumed and finished (succeeded) just now
      wf_a = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 2.hours.ago,
        finished_at: 1.minute.ago
      )

      row = described_class.where(id: job.id).with_latest_workflow_snapshot.first

      expect(row.latest_workflow_id).to eq(wf_a.id)
      expect(row.latest_workflow_state).to eq("succeeded")
      expect(row.latest_workflow_trigger_kind).to eq("initial")
    end

    it "ranks an in-progress workflow ahead of a more recently created but finished workflow" do
      job = Factories.job_record(issue_number: 2, issue_title: "Grade the via")
      # WF-B created more recently but already failed
      Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "failed",
        created_at: 1.hour.ago,
        finished_at: 45.minutes.ago
      )
      # WF-A created earlier and still running (finished_at is NULL)
      wf_a = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        created_at: 2.hours.ago,
        finished_at: nil
      )

      row = described_class.where(id: job.id).with_latest_workflow_snapshot.first

      expect(row.latest_workflow_id).to eq(wf_a.id)
      expect(row.latest_workflow_state).to eq("running")
    end
  end

  describe "#latest_workflow" do
    it "prefers the most recently finished workflow over the most recently created one" do
      job = Factories.job_record(issue_number: 1, issue_title: "Pave the forum")
      wf_b = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "failed",
        created_at: 1.hour.ago,
        finished_at: 30.minutes.ago
      )
      wf_a = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 2.hours.ago,
        finished_at: 1.minute.ago
      )

      expect(job.reload.latest_workflow).to eq(wf_a)
    end

    it "ranks an in-progress workflow (nil finished_at) ahead of a finished one" do
      job = Factories.job_record(issue_number: 2, issue_title: "Raise the aqueduct")
      Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "failed",
        created_at: 1.hour.ago,
        finished_at: 45.minutes.ago
      )
      wf_running = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        created_at: 2.hours.ago,
        finished_at: nil
      )

      expect(job.reload.latest_workflow).to eq(wf_running)
    end
  end

  describe ".without_active_workflows" do
    it "excludes jobs with queued or running workflows" do
      idle = Factories.job_record(issue_number: 1, issue_title: "Ready")
      queued = Factories.job_record(repository: idle.repository, issue_number: 2, issue_title: "Queued workflow")
      running = Factories.job_record(repository: idle.repository, issue_number: 3, issue_title: "Running workflow")
      terminal = Factories.job_record(repository: idle.repository, issue_number: 4, issue_title: "Done workflow")

      Workflow.create!(job: queued, trigger_kind: "manual", state: "queued")
      Workflow.create!(job: running, trigger_kind: "manual", state: "running")
      Workflow.create!(job: terminal, trigger_kind: "manual", state: "succeeded")

      expect(described_class.where(id: [ idle.id, queued.id, running.id, terminal.id ]).without_active_workflows).to contain_exactly(
        idle,
        terminal
      )
    end
  end

  describe "thread state machine" do
    it "starts as an open thread" do
      job = Factories.job
      expect(job).to be_open
    end

    it "transitions queued → closed via close!" do
      job = Factories.job
      expect { job.close! }.to change(job, :state).from("queued").to("closed")
    end

    it "captures finished_at on close" do
      job = Factories.job
      freeze_time do
        job.close!
        expect(job.finished_at).to eq(Time.current)
      end
    end

    it "resets commits_behind_base to nil on close" do
      job = Factories.job
      job.update_columns(commits_behind_base: 7)
      job.close!
      expect(job.reload.commits_behind_base).to be_nil
    end

    it "stores closure_reason via close_with_reason!" do
      job = Factories.job
      job.close_with_reason!("manual")
      expect(job).to be_closed
      expect(job.closure_reason).to eq("manual")
    end

    it "closes main_grader jobs instead of leaving them implemented" do
      user = Factories.user
      repository = Factories.repository(user: user)
      job = Job.create!(
        user: user,
        owner_user: user,
        repository: repository,
        kind: "main_grader",
        issue_title: "main_grader:abc123",
        issue_number: nil,
        state: "running"
      )

      freeze_time do
        expect { job.mark_implemented! }
          .to change(job, :state).from("running").to("closed")

        expect(job.closure_reason).to eq(Job::MAIN_GRADER_CLOSURE_REASON)
        expect(job.finished_at).to eq(Time.current)
      end
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

    it "purges coverage hit maps on all workflows when the job closes" do
      job = Factories.job
      hit_map = instance_double(ActiveStorage::Attached::One, attached?: true)
      allow_any_instance_of(Workflow).to receive(:coverage_hit_map).and_return(hit_map)
      expect_any_instance_of(Workflow).to receive(:purge_coverage_hit_map!)

      job.reload.close!
    end

    it "skips coverage hit map purge for workflows without an attached map" do
      job = Factories.job
      hit_map = instance_double(ActiveStorage::Attached::One, attached?: false)
      allow_any_instance_of(Workflow).to receive(:coverage_hit_map).and_return(hit_map)
      expect_any_instance_of(Workflow).not_to receive(:purge_coverage_hit_map!)

      job.reload.close!
    end

    it "reopen! transitions closed → triaging and clears closure_reason + finished_at" do
      job = Factories.job
      job.close_with_reason!("cancelled")
      expect(job.closure_reason).to eq("cancelled")
      expect(job.finished_at).to be_present

      job.reopen!
      job.save!

      expect(job.state).to eq("triaging")
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

    it "approves an implemented job with approval metadata" do
      job = Factories.job
      job.update!(state: "implemented")

      freeze_time do
        expect {
          job.approve!(
            via: "operator",
            by_user: job.user,
            evidence: { "note" => "reviewed in Syrus" },
            at: Time.current
          )
        }.to change(job, :state).from("implemented").to("approved")

        expect(job.approved_at).to eq(Time.current)
        expect(job.approved_via).to eq("operator")
        expect(job.approved_by_user).to eq(job.user)
        expect(job.approval_evidence).to eq("note" => "reviewed in Syrus")
      end
    end

    it "moves an approved job into landing and then closed (post :merged removal)" do
      job = Factories.job
      job.update!(state: "implemented")
      job.approve!(via: "bulk", by_user: job.user)

      expect { job.start_landing! }.to change(job, :state).from("approved").to("landing")
      # :merged was removed (audit finding 2); merge path is now
      # close(closure_reason: "pr_merged") from :landing.
      expect { job.close_with_reason!("pr_merged") }.to change(job, :state).from("landing").to("closed")
      expect(job.finished_at).to be_present
      expect(job.closure_reason).to eq("pr_merged")
    end

    it "unapproves an approved job back to implemented and clears metadata" do
      job = Factories.job
      job.update!(state: "implemented")
      job.approve!(via: "operator", by_user: job.user, evidence: { "note" => "ship it" })

      expect { job.unapprove! }.to change(job, :state).from("approved").to("implemented")
      expect(job.approved_at).to be_nil
      expect(job.approved_via).to be_nil
      expect(job.approved_by_user).to be_nil
      expect(job.approval_evidence).to eq({})
    end

    it "does not allow unapproving a landing job" do
      job = Factories.job
      job.update!(state: "implemented")
      job.approve!(via: "operator", by_user: job.user)
      job.start_landing!

      expect(job.may_unapprove?).to be false
      expect { job.unapprove! }.to raise_error(AASM::InvalidTransition)
      expect(job.state).to eq("landing")
    end

    it "enters coding state from implemented via enter_local_mode" do
      job = Factories.job_record(state: "implemented")

      expect { job.enter_local_mode! }.to change(job, :state).from("implemented").to("coding")
    end

    it "exits coding state back to implemented via exit_local_mode" do
      job = Factories.job_record(state: "implemented")
      job.update_columns(state: "coding")

      expect { job.exit_local_mode! }.to change(job, :state).from("coding").to("implemented")
    end

    it "can close a job in coding state" do
      job = Factories.job_record(state: "implemented")
      job.update_columns(state: "coding")

      expect(job.may_close?).to be true
    end

    describe "#record_github_review_approval!" do
      it "creates a JobApproval for the reviewer and approves when policy is satisfied" do
        job = Factories.job
        job.update!(state: "implemented")
        submitted = 2.hours.ago

        # Pass the job owner as reviewer; SelfPolicy (default) requires the owner's approval
        expect {
          job.record_github_review_approval!(
            review_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1",
            approved_at: submitted,
            reviewer_user: job.user
          )
        }.to change { job.job_approvals.count }.by(1)
          .and change { job.reload.state }.from("implemented").to("approved")

        approval = job.job_approvals.find_by(user: job.user)
        expect(approval.approved_at).to be_within(1.second).of(submitted)
        expect(job.approved_via).to eq("github_review")
        expect(job.approval_evidence).to eq("github_review_url" => "https://github.com/acme/widgets/pull/7#pullrequestreview-1")
      end

      it "falls back to the job owner when reviewer_user is nil" do
        job = Factories.job
        job.update!(state: "implemented")

        job.record_github_review_approval!(
          review_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1",
          approved_at: Time.current
        )

        expect(job.job_approvals.find_by(user: job.user)).to be_present
        expect(job.reload.state).to eq("approved")
      end

      it "is idempotent: does not duplicate an existing JobApproval" do
        job = Factories.job
        job.update!(state: "implemented")
        job.job_approvals.create!(user: job.user, approved_at: 2.hours.ago)

        expect {
          job.record_github_review_approval!(
            review_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1",
            approved_at: 1.hour.ago,
            reviewer_user: job.user
          )
        }.not_to change { job.job_approvals.count }

        expect(job.reload.state).to eq("approved")
      end

      it "creates a JobApproval without approving when policy is not yet met" do
        repository = Factories.repository(review_policy: "two_person")
        owner = Factories.user
        job = Factories.job(user: owner, repository: repository, owner_user: owner)
        job.update!(state: "implemented")
        non_owner = Factories.user

        result = job.record_github_review_approval!(
          review_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1",
          approved_at: Time.current,
          reviewer_user: non_owner
        )

        expect(result).to be false
        expect(job.reload.state).to eq("implemented")
        expect(job.job_approvals.find_by(user: non_owner)).to be_present
      end

      it "returns false and does nothing when job cannot transition to approved" do
        job = Factories.job
        job.update!(state: "approved")

        expect {
          job.record_github_review_approval!(
            review_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1",
            approved_at: Time.current
          )
        }.not_to change { job.job_approvals.count }
      end
    end

describe "running / failed lifecycle (new in this commit)" do
      it "transitions :queued → :running via start_running!" do
        job = Factories.job_record(state: "queued")
        expect { job.start_running!; job.save! }
          .to change { job.reload.state }.from("queued").to("running")
      end

      it "transitions :implemented → :running via start_running! (follow-up workflow)" do
        job = Factories.job_record(state: "implemented")
        expect { job.start_running!; job.save! }
          .to change { job.reload.state }.from("implemented").to("running")
      end

      it "transitions :running → :implemented via mark_implemented!" do
        job = Factories.job_record(state: "running")
        expect { job.mark_implemented!; job.save! }
          .to change { job.reload.state }.from("running").to("implemented")
      end

      it "transitions :running → :failed via mark_failed!" do
        job = Factories.job_record(state: "running")
        expect { job.mark_failed!; job.save! }
          .to change { job.reload.state }.from("running").to("failed")
      end

      it "transitions :failed → :queued via retry_after_failure!" do
        job = Factories.job_record(state: "failed")
        expect { job.retry_after_failure!; job.save! }
          .to change { job.reload.state }.from("failed").to("queued")
      end

      it "mark_failed! is illegal from anything except :running" do
        %w[triaging queued implemented approved landing closed].each do |state|
          job = Factories.job_record(state: state)
          expect(job.may_mark_failed?).to be(false), "expected may_mark_failed? to be false from :#{state}"
        end
      end

      it "force_fail! transitions open non-failed states to :failed" do
        %w[needs_triage triaging blocked_by_epic queued running implemented coding no_change_needed approved landing].each do |state|
          job = Factories.job_record(state: state)
          expect { job.force_fail!; job.save! }
            .to change { job.reload.state }.from(state).to("failed")
        end
      end

      it "force_fail! is illegal from :failed and :closed" do
        %w[failed closed].each do |state|
          job = Factories.job_record(state: state)
          expect(job.may_force_fail?).to be(false), "expected may_force_fail? to be false from :#{state}"
        end
      end

      it "transitions :running → :no_change_needed via mark_no_change_needed!" do
        job = Factories.job_record(state: "running")
        expect { job.mark_no_change_needed!; job.save! }
          .to change { job.reload.state }.from("running").to("no_change_needed")
      end

      it "mark_no_change_needed! is illegal from anything except :running" do
        %w[triaging queued implemented approved landing failed closed].each do |state|
          job = Factories.job_record(state: state)
          expect(job.may_mark_no_change_needed?).to be(false), "expected may_mark_no_change_needed? to be false from :#{state}"
        end
      end

      it "no_change_needed? returns true only from :no_change_needed" do
        job = Factories.job_record(state: "no_change_needed")
        expect(job.no_change_needed?).to be(true)

        other = Factories.job_record(state: "failed")
        expect(other.no_change_needed?).to be(false)
      end

      it "start_running! is illegal from :triaging / :approved / :landing / :failed / :closed" do
        %w[triaging approved landing failed closed].each do |state|
          job = Factories.job_record(state: state)
          expect(job.may_start_running?).to be(false), "expected may_start_running? to be false from :#{state}"
        end
      end

      it "close! accepts :running and :failed (operator gives up)" do
        running = Factories.job_record(state: "running")
        running.close!; running.save!
        expect(running.reload).to be_closed

        failed = Factories.job_record(state: "failed")
        failed.close!; failed.save!
        expect(failed.reload).to be_closed
      end

      it "close! accepts :no_change_needed (operator acknowledges work was already done)" do
        job = Factories.job_record(state: "no_change_needed")
        expect { job.close!; job.save! }
          .to change { job.reload.state }.from("no_change_needed").to("closed")
      end

      it "no_change_needed job is open? (semi-terminal)" do
        job = Factories.job_record(state: "no_change_needed")
        expect(job.open?).to be(true)
        expect(job.closed?).to be(false)
      end
    end

    it "does not allow approving a closed (merged) job" do
      job = Factories.job
      job.update!(state: "closed", closure_reason: "pr_merged")

      expect(job.may_approve?).to be false
      expect { job.approve!(via: "operator", by_user: job.user) }.to raise_error(AASM::InvalidTransition)
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

    it "uses the job's future workflow provider for alternate manual action choices" do
      job.update!(agent_provider: "codex")

      expect(job.alternate_configured_agent_providers).to eq([ "codex" ])
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

  describe "#record_outcome_to_scheduled_task!" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:task) do
      ScheduledTask.create!(
        user: user, repository: repository,
        name: "Hourly sweep", prompt: "do the thing",
        kind: "cron", cron_expression: "0 * * * *"
      )
    end
    let(:cron_job) do
      Job.create!(user: user, repository: repository, kind: "cron", scheduled_task: task)
    end

    it "calls record_success! on the scheduled_task for normal closure reasons" do
      cron_job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
      expect(task).to receive(:record_success!)
      cron_job.send(:record_outcome_to_scheduled_task!)
    end

    it "calls record_failure! when closure_reason is too_many_failures" do
      cron_job.update!(state: "closed", closure_reason: "too_many_failures", finished_at: Time.current)
      expect(task).to receive(:record_failure!)
      cron_job.send(:record_outcome_to_scheduled_task!)
    end

    it "calls neither record_success! nor record_failure! when replaced_by_scheduled_task" do
      cron_job.update!(state: "closed", closure_reason: "replaced_by_scheduled_task", finished_at: Time.current)
      expect(task).not_to receive(:record_success!)
      expect(task).not_to receive(:record_failure!)
      cron_job.send(:record_outcome_to_scheduled_task!)
    end

    it "is a no-op when job has no scheduled_task" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
      expect { job.send(:record_outcome_to_scheduled_task!) }.not_to raise_error
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

  describe "triage lifecycle" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "creates issue jobs in triaging with classifier_pending reason and no run" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)

      expect(job.state).to eq("triaging")
      expect(job.triaging_reason).to eq("classifier_pending")
      expect(job.validity).to eq("valid")
      expect(job.runs).to be_empty
    end

    it "queues a valid triaged issue job and creates its initial run" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)

      expect { job.advance_after_triage! }
        .to change { job.reload.state }.from("triaging").to("queued")
        .and change { job.runs.count }.from(0).to(1)
    end

it "auto-creates and starts a workflow for direct jobs on advance_after_triage" do
      job = Job.create!(user: user, repository: repository, kind: "direct",
                        issue_number: nil, issue_title: "t", issue_body: "do a thing")

      expect { job.advance_after_triage! }
        .to change { job.reload.state }.from("triaging").to("queued")
        .and change { job.workflows.count }.by(1)
        .and change { job.runs.count }.by(1)

      expect(job.workflows.first.trigger_kind).to eq("initial")
      expect(job.runs.first.prompt).to include("do a thing")
    end

    it "renders Prompts::DirectJob for direct jobs' initial run prompt" do
      job = Job.create!(user: user, repository: repository, kind: "direct",
                        issue_number: nil, issue_title: "t", issue_body: "specific body")
      job.advance_after_triage!

      expect(job.runs.first.prompt).to eq(Prompts::DirectJob.new(prompt: "specific body").to_s)
    end

    it "includes Epic context in direct child jobs' initial run prompt" do
      epic = Factories.epic(
        user: user,
        repository: repository,
        title: "Syrus CLI and test planning",
        description: "The Epic combines a Rails workflow track with a Go CLI track.",
        state: "in_progress"
      )
      job = Job.create!(user: user, repository: repository, epic: epic, kind: "direct",
                        issue_number: nil, issue_title: "t", issue_body: "Build the Go checkout command.")

      job.advance_after_triage!

      prompt = job.runs.first.prompt
      expect(prompt).to include("Build the Go checkout command.")
      expect(prompt).to include("#{epic.slug}: Syrus CLI and test planning")
      expect(prompt).to include("Do not implement the entire Epic")
      expect(prompt).to include("Implement only the Job described above")
    end

    it "does not create a workflow for cron jobs (those are seeded by PollScheduledTasksJob)" do
      task = ScheduledTask.create!(
        user: user, repository: repository, kind: "one_shot",
        name: "smoke test", fire_at: 1.hour.from_now, prompt: "do the thing"
      )
      job = Job.create!(user: user, repository: repository, kind: "cron",
                        scheduled_task: task)

      expect { job.advance_after_triage! }
        .to change { job.reload.state }.from("triaging").to("queued")
        .and change { job.workflows.count }.by(0)
        .and change { job.runs.count }.by(0)
    end

    it "keeps duplicate jobs out of the queue" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      job.update!(
        validity: "duplicate",
        invalidation_reason: "Human PR already covers this.",
        invalidation_evidence: [ "https://github.com/acme/widgets/pull/12" ]
      )

      expect(job.may_advance_after_triage?).to be false
      expect { job.advance_after_triage! }.not_to change { job.reload.state }
      expect(job.runs).to be_empty
    end

    it "lets an operator mark a closed invalid job valid and queue it" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      job.update!(
        state: "closed",
        closure_reason: "duplicate",
        finished_at: Time.current,
        validity: "duplicate",
        invalidation_reason: "Already covered.",
        invalidation_evidence: [ "https://github.com/acme/widgets/issues/2" ]
      )

      expect { job.mark_valid_and_queue! }
        .to change { job.reload.state }.from("closed").to("queued")
        .and change { job.runs.count }.from(0).to(1)

      expect(job.closure_reason).to be_nil
      expect(job.finished_at).to be_nil
      expect(job.validity).to eq("valid")
    end

    it "blocks on backlog epics and queues when the epic enters in_progress" do
      epic = Factories.epic(user: user, repository: repository, state: "backlog")
      job = Job.create!(user: user, repository: repository, issue_number: 1, epic: epic)

      expect { job.advance_after_triage! }
        .to change { job.reload.state }.from("triaging").to("blocked_by_epic")
      expect(job.runs).to be_empty

      expect { epic.in_progress! }
        .to change { job.reload.state }.from("blocked_by_epic").to("queued")
        .and change { job.runs.count }.from(0).to(1)
    end

    it "keeps jobs blocked when the parent in_progress epic has unsatisfied EpicDependency records" do
      blocker = Factories.epic(user: user, repository: repository, state: "in_progress")
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      EpicDependency.create!(epic: epic, depends_on_epic: blocker)
      job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 10, state: "blocked_by_epic")

      expect(job.blocked_by_epic_before_execution?).to be true
      expect(job.may_advance_after_triage?).to be false
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

    it "accepts urgent, high, medium, and low" do
      %w[urgent high medium low].each do |p|
        job = Job.new(user: user, repository: repository, issue_number: 1, priority: p)
        expect(job).to be_valid, "expected #{p} to be valid"
      end
    end

    it "rejects unknown priority values" do
      job = Job.new(user: user, repository: repository, issue_number: 1, priority: "critical")
      expect(job).not_to be_valid
      expect(job.errors[:priority]).to be_present
    end

    describe "#solid_queue_priority" do
      it "maps urgent to a lower integer than high" do
        urgent_job = Job.new(priority: "urgent")
        high_job = Job.new(priority: "high")
        expect(urgent_job.solid_queue_priority).to be < high_job.solid_queue_priority
      end

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

  describe "#approval_satisfied?" do
    let(:owner) { Factories.user }
    let(:other) { Factories.user }

    context "review_policy: self" do
      it "returns false when no approvals exist" do
        repo = Factories.repository(user: owner, review_policy: "self")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        expect(job.approval_satisfied?).to be false
      end

      it "returns true when owner has approved" do
        repo = Factories.repository(user: owner, review_policy: "self")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        JobApproval.create!(job: job, user: owner)
        expect(job.approval_satisfied?).to be true
      end

      it "returns false when only a non-owner has approved" do
        repo = Factories.repository(user: owner, review_policy: "self")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        JobApproval.create!(job: job, user: other)
        expect(job.approval_satisfied?).to be false
      end
    end

    context "review_policy: two_person" do
      it "returns false when only the owner has approved" do
        repo = Factories.repository(user: owner, review_policy: "two_person")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        JobApproval.create!(job: job, user: owner)
        expect(job.approval_satisfied?).to be false
      end

      it "returns false when only a non-owner has approved" do
        repo = Factories.repository(user: owner, review_policy: "two_person")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        JobApproval.create!(job: job, user: other)
        expect(job.approval_satisfied?).to be false
      end

      it "returns true when owner and one other user have approved" do
        repo = Factories.repository(user: owner, review_policy: "two_person")
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        JobApproval.create!(job: job, user: owner)
        JobApproval.create!(job: job, user: other)
        expect(job.approval_satisfied?).to be true
      end
    end

    context "review_policy: final_say" do
      it "collapses to self when owner is a final approver" do
        repo = Factories.repository(user: owner, review_policy: "final_say")
        RepositoryFinalApprover.create!(repository: repo, user: owner)
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        expect(job.approval_satisfied?).to be false
        JobApproval.create!(job: job, user: owner)
        expect(job.approval_satisfied?).to be true
      end

      it "requires owner approval and a final approver when owner is not a final approver" do
        final_approver = Factories.user
        repo = Factories.repository(user: owner, review_policy: "final_say")
        RepositoryFinalApprover.create!(repository: repo, user: final_approver)
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")

        JobApproval.create!(job: job, user: owner)
        expect(job.approval_satisfied?).to be false

        JobApproval.create!(job: job, user: final_approver)
        expect(job.approval_satisfied?).to be true
      end

      it "returns false when only a non-final-approver has approved alongside the owner" do
        repo = Factories.repository(user: owner, review_policy: "final_say")
        RepositoryFinalApprover.create!(repository: repo, user: other)
        job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
        random_user = Factories.user
        JobApproval.create!(job: job, user: owner)
        JobApproval.create!(job: job, user: random_user)
        expect(job.approval_satisfied?).to be false
      end
    end
  end

  describe "#can_add_job_approval?" do
    let(:owner) { Factories.user }
    let(:creator) { Factories.user }
    let(:other) { Factories.user }

    it "allows the owner to approve even when they are also the creator" do
      repo = Factories.repository(user: owner)
      job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
      expect(job.can_add_job_approval?(owner)).to be true
    end

    it "allows the creator to approve when owner_user_id is nil" do
      repo = Factories.repository(user: owner)
      job = Factories.job_record(user: owner, repository: repo, state: "implemented")
      job.update_column(:owner_user_id, nil)
      expect(job.can_add_job_approval?(owner)).to be true
    end

    it "blocks the creator when they are not the owner" do
      repo = Factories.repository(user: owner)
      job = Factories.job_record(user: creator, owner_user: owner, repository: repo, state: "implemented")
      expect(job.can_add_job_approval?(creator)).to be false
    end

    it "allows a non-creator non-owner to approve" do
      repo = Factories.repository(user: owner)
      job = Factories.job_record(user: creator, owner_user: owner, repository: repo, state: "implemented")
      expect(job.can_add_job_approval?(other)).to be true
    end

    it "returns false when job is not implemented" do
      repo = Factories.repository(user: owner)
      job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "queued")
      expect(job.can_add_job_approval?(owner)).to be false
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

    it "does not seed parsed dependencies for direct jobs" do
      Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_body: "Depends-on: #123"
      )

      expect(JobDependency.count).to eq(0)
    end

    it "does not seed parsed dependencies for cron jobs" do
      task = ScheduledTask.create!(
        user: user,
        repository: repository,
        name: "Hourly maintenance",
        prompt: "Audit the repository.",
        kind: "cron",
        cron_expression: "0 * * * *"
      )

      Job.create!(
        user: user,
        repository: repository,
        kind: "cron",
        scheduled_task: task,
        issue_number: nil,
        issue_body: "Depends-on: #123"
      )

      expect(JobDependency.count).to eq(0)
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

    it "treats pending dependencies on done Epic issues as satisfied" do
      Epic.create!(
        user: user,
        repository: repository,
        title: "Finished prerequisite",
        github_issue_url: "https://github.com/#{repository.owner}/#{repository.name}/issues/999",
        state: "done",
        done_at: Time.current
      )
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #999"
      )

      expect(job.dependencies.first).to be_pending
      expect(job).to be_dependencies_satisfied
      expect(job.unsatisfied_dependencies).to be_empty
      expect(job).to be_stack_ready_for_execution
    end

    it "keeps pending dependencies on unfinished Epic issues unsatisfied" do
      Epic.create!(
        user: user,
        repository: repository,
        title: "Unfinished prerequisite",
        github_issue_url: "https://github.com/#{repository.owner}/#{repository.name}/issues/999",
        state: "in_progress"
      )
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #999"
      )

      expect(job.dependencies.first).to be_pending
      expect(job).not_to be_dependencies_satisfied
      expect(job.unsatisfied_dependencies.size).to eq(1)
      expect(job).not_to be_stack_ready_for_execution
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

    it "treats no_changes as a successful dependency closure" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #42")

      prerequisite.close_with_reason!("no_changes")

      expect(job.reload).to be_dependencies_satisfied
      expect(job).to be_stack_ready_for_execution
      expect(job.parent_job).to be_nil
    end

    it "treats an approved same-epic dependency as satisfied for execution" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      prerequisite = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 42, state: "approved")
      job = Job.create!(user: user, repository: repository, epic: epic, issue_number: 43, issue_body: "Depends-on: #42")

      expect(job.reload).to be_dependencies_satisfied
    end

    it "can start on an approved same-epic dependency and stacks on its branch" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      prerequisite = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 42, state: "approved",
        branch_name: "syrus/issue-42", pr_number: 7
      )
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "a" * 40)
      job = Job.create!(user: user, repository: repository, epic: epic, issue_number: 43, issue_body: "Depends-on: #42")

      expect(job.reload).to be_dependencies_satisfied
      expect(job).to be_stack_ready_for_execution
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "blocks when multiple same-epic dependencies are approved but not yet merged" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress", epic_dependency_policy: "nonlinear")
      dep_a = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 41, state: "approved",
        branch_name: "syrus/issue-41", pr_number: 6
      )
      dep_a.runs.create!(trigger_kind: "initial", agent_provider: dep_a.agent_provider, head_sha: "a" * 40)
      dep_b = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 42, state: "approved",
        branch_name: "syrus/issue-42", pr_number: 7
      )
      dep_b.runs.create!(trigger_kind: "initial", agent_provider: dep_b.agent_provider, head_sha: "b" * 40)
      job = Job.create!(
        user: user, repository: repository, epic: epic, issue_number: 43,
        issue_body: "Depends-on: #41\nDepends-on: #42"
      )

      expect(job.reload).to be_dependencies_satisfied
      expect(job).not_to be_stack_ready_for_execution
    end

    it "collapses redundant transitive same-epic dependencies to the most-downstream parent" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      root = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 41, state: "approved",
        branch_name: "syrus/issue-41", pr_number: 6
      )
      root.runs.create!(trigger_kind: "initial", agent_provider: root.agent_provider, head_sha: "a" * 40)
      middle = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 42, state: "approved",
        branch_name: "syrus/issue-42", pr_number: 7
      )
      middle.runs.create!(trigger_kind: "initial", agent_provider: middle.agent_provider, head_sha: "b" * 40)
      JobDependency.create!(job: middle, depends_on_job: root, source: "manual")
      leaf = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 43, state: "approved"
      )
      root_dependency = JobDependency.create!(job: leaf, depends_on_job: root, source: "manual")
      middle_dependency = JobDependency.create!(job: leaf, depends_on_job: middle, source: "manual")

      expect(leaf.reload).to be_dependencies_satisfied
      expect(leaf).to be_stack_ready_for_execution
      expect(leaf.reload.parent_job).to eq(middle)
      expect(leaf.effective_base_branch).to eq("syrus/issue-42")
      expect(JobDependency.where(id: [ root_dependency.id, middle_dependency.id ]).count).to eq(2)
    end

    it "can start on a single open dependency by making it the stack parent" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      prerequisite.update!(branch_name: "syrus/issue-42-#{prerequisite.id}", pr_number: 7)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "a" * 40)
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #42")

      expect(job).not_to be_dependencies_satisfied
      expect(job).to be_stack_ready_for_execution
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "starts a dependent queued workflow when the parent reaches implemented with an open PR" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      prerequisite.advance_after_triage!
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #42")
      job.advance_after_triage!
      first_step = job.reload.latest_workflow.first_step

      expect(job).to be_queued
      expect(first_step.runs.count).to eq(0)

      prerequisite.update!(branch_name: "syrus/issue-42-#{prerequisite.id}", pr_number: 7)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "a" * 40)

      expect {
        prerequisite.mark_implemented!
        prerequisite.save!
      }.to change { first_step.runs.reload.count }.by(1)
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "starts a dependent queued workflow when a same-Epic dependency is approved, stacking on its branch" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      prerequisite = Job.create!(user: user, repository: repository, epic: epic, issue_number: 42)
      prerequisite.advance_after_triage!
      job = Job.create!(user: user, repository: repository, epic: epic, issue_number: 43, issue_body: "Depends-on: #42")
      job.advance_after_triage!
      first_step = job.reload.latest_workflow.first_step

      expect(job).to be_queued
      expect(first_step.runs.count).to eq(0)

      prerequisite.update!(branch_name: "syrus/issue-42-#{prerequisite.id}", pr_number: 7)
      prerequisite.runs.update_all(head_sha: "a" * 40)
      prerequisite.update_columns(state: "implemented")

      expect {
        prerequisite.approve!(via: "github_review")
        prerequisite.save!
      }.to change { first_step.runs.reload.count }.by(1)
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "eagerly starts a linear same-Epic stack as each parent is implemented" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      first = Job.create!(user: user, repository: repository, epic: epic, issue_number: 41)
      first.advance_after_triage!
      second = Job.create!(user: user, repository: repository, epic: epic, issue_number: 42, issue_body: "Depends-on: #41")
      second.advance_after_triage!
      third = Job.create!(user: user, repository: repository, epic: epic, issue_number: 43, issue_body: "Depends-on: #42")
      third.advance_after_triage!
      second_first_step = second.reload.latest_workflow.first_step
      third_first_step = third.reload.latest_workflow.first_step

      expect(second).to be_queued
      expect(third).to be_queued
      expect(second_first_step.runs.count).to eq(0)
      expect(third_first_step.runs.count).to eq(0)

      first.update!(branch_name: "syrus/issue-41-#{first.id}", pr_number: 6)
      first.runs.update_all(head_sha: "a" * 40)

      expect {
        first.mark_implemented!
        first.save!
      }.to change { second_first_step.runs.reload.count }.by(1)
      expect(second.reload.parent_job).to eq(first)
      expect(second).not_to be_dependencies_satisfied

      second.update!(branch_name: "syrus/issue-42-#{second.id}", pr_number: 7)
      second.runs.update_all(head_sha: "b" * 40)

      expect {
        second.mark_implemented!
        second.save!
      }.to change { third_first_step.runs.reload.count }.by(1)
      expect(third.reload.parent_job).to eq(second)
      expect(third).not_to be_dependencies_satisfied
    end

    it "keeps nonlinear same-Epic children blocked until stack readiness is unambiguous" do
      epic = Factories.epic(
        user: user,
        repository: repository,
        state: "in_progress",
        epic_dependency_policy: "nonlinear"
      )
      first = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 41,
        state: "implemented", branch_name: "syrus/issue-41", pr_number: 6
      )
      first.runs.create!(trigger_kind: "initial", agent_provider: first.agent_provider, head_sha: "a" * 40)
      second = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 42,
        state: "implemented", branch_name: "syrus/issue-42", pr_number: 7
      )
      second.runs.create!(trigger_kind: "initial", agent_provider: second.agent_provider, head_sha: "b" * 40)
      child = Job.create!(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 43,
        issue_body: "Depends-on: #41\nDepends-on: #42"
      )
      child.advance_after_triage!
      first_step = child.reload.latest_workflow.first_step

      expect(child).to be_dependencies_satisfied_for_execution
      expect(child).not_to be_dependencies_satisfied
      expect(child).not_to be_stack_ready_for_execution
      expect(first_step.runs.count).to eq(0)

      first.close_with_reason!("pr_merged")

      expect(child.reload).to be_stack_ready_for_execution
      expect(child.parent_job).to eq(second)
    end

    it "waits on multiple unmerged dependencies until only one remains as parent" do
      first = Job.create!(user: user, repository: repository, issue_number: 41)
      second = Job.create!(user: user, repository: repository, issue_number: 42)
      second.update!(branch_name: "syrus/issue-42-#{second.id}", pr_number: 8)
      second.runs.create!(trigger_kind: "initial", agent_provider: second.agent_provider, head_sha: "b" * 40)
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #41\nDepends-on: #42")

      expect(job).not_to be_stack_ready_for_execution

      first.close_with_reason!("pr_merged")

      expect(job.reload).to be_stack_ready_for_execution
      expect(job.parent_job).to eq(second)
    end

    it "waits when the only remaining dependency closed without merging" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      job = Job.create!(user: user, repository: repository, issue_number: 43, issue_body: "Depends-on: #42")

      prerequisite.close_with_reason!("pr_closed")

      expect(job.reload).not_to be_stack_ready_for_execution
      expect(job.parent_job).to be_nil
    end

    it "forces main when stack_base is main" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 42)
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: 43,
        issue_body: "Depends-on: #42",
        stack_base: "main"
      )

      expect(job).to be_stack_ready_for_execution
      expect(job.reload.parent_job).to be_nil
      expect(job).not_to be_dependencies_satisfied
    end

    it "allows same-epic dependencies to stack even when stack_base is main" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Job.create!(user: user, repository: repository, epic: epic, issue_number: 42)
      prerequisite.update!(branch_name: "syrus/issue-42-#{prerequisite.id}", pr_number: 7)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "a" * 40)
      job = Job.create!(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 43,
        issue_body: "Depends-on: #42",
        stack_base: "main"
      )

      expect(job).to be_stack_ready_for_execution
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "releases blocked_by_epic and starts the workflow when a same-epic dep resolves after the epic is already in_progress" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")
      prerequisite = Factories.job_record(
        user: user, repository: repository, epic: epic, issue_number: 42,
        state: "implemented", branch_name: "syrus/issue-42", pr_number: 7
      )
      job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")
      workflow = Workflows::Initial.instantiate(job: job)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
      epic.update_columns(state: "in_progress")

      expect(job).to be_blocked_by_epic
      expect(workflow.first_step.runs).to be_empty

      expect {
        prerequisite.approve!(via: "operator")
        prerequisite.save!
      }.to change { job.reload.state }.from("blocked_by_epic").to("queued")
        .and change { workflow.first_step.runs.reload.count }.by(1)
    end

    it "does not release blocked_by_epic when epic is in_progress but job-level dep is still unsatisfied" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "queued")
      job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      job.start_pending_workflows_if_dependencies_satisfied!

      expect(job.reload).to be_blocked_by_epic
    end
  end

  describe "#effective_base_branch" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user, default_branch: "main") }

    it "returns an open dependency's PR branch when the dependency has not merged" do
      parent = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 41,
        state: "queued",
        branch_name: "syrus/issue-41",
        pr_number: 41
      )
      child = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "queued")
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: user)

      expect(child.effective_base_branch).to eq("syrus/issue-41")
    end

    it "returns the default branch after the dependency merges" do
      parent = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 41,
        state: "closed",
        closure_reason: "pr_merged",
        branch_name: "syrus/issue-41",
        pr_number: 41
      )
      child = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "queued")
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: user)

      expect(child.effective_base_branch).to eq("main")
    end

    it "returns the default branch for a closed non-PR dependency" do
      parent = Factories.job_record(
        user: user,
        repository: repository,
        issue_number: 41,
        state: "closed",
        closure_reason: "duplicate"
      )
      child = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "queued")
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: user)

      expect(child.effective_base_branch).to eq("main")
    end

    it "returns a same-epic dependency branch when stack_base is main" do
      epic = Factories.epic(user: user, repository: repository)
      parent = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 41,
        state: "implemented",
        branch_name: "syrus/issue-41",
        pr_number: 41
      )
      child = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 42,
        state: "queued",
        stack_base: "main"
      )
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: user)

      expect(child.effective_base_branch).to eq("syrus/issue-41")
    end
  end

  describe "#effective_target_repository" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "returns the repository when target_repository_id is nil" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      expect(job.effective_target_repository).to eq(repository)
    end

    it "returns the target_repository when one is set" do
      upstream = Factories.repository(user: user)
      fork = Factories.repository(user: user, upstream_repository: upstream)
      epic = Epic.create!(user: user, repository: upstream, title: "Cross-fork epic")
      job = Job.create!(user: user, repository: fork, epic: epic, issue_number: 5)
      expect(job.effective_target_repository).to eq(upstream)
    end
  end

  describe "#effective_pr_repository" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "returns the repository when pr_repository_id is nil" do
      job = Job.create!(user: user, repository: repository, issue_number: 1)
      expect(job.effective_pr_repository).to eq(repository)
    end

    it "returns pr_repository when one is set" do
      upstream = Factories.repository(user: user)
      job = Job.create!(user: user, repository: repository, issue_number: 6, pr_repository: upstream)
      expect(job.effective_pr_repository).to eq(upstream)
    end
  end

  describe "target_repository_id auto-population" do
    let(:user) { Factories.user }

    it "leaves target_repository_id nil for a job on a non-fork repository without an epic" do
      repo = Factories.repository(user: user)
      job = Job.create!(user: user, repository: repo, issue_number: 1)
      expect(job.target_repository_id).to be_nil
    end

    it "leaves target_repository_id nil for a job on the canonical repo directly under its own epic" do
      repo = Factories.repository(user: user)
      epic = Epic.create!(user: user, repository: repo, title: "Same-repo epic")
      job = Job.create!(user: user, repository: repo, epic: epic, issue_number: 2)
      expect(job.target_repository_id).to be_nil
    end

    it "sets target_repository_id to the upstream when the job repo is a fork whose upstream is the epic repo" do
      upstream = Factories.repository(user: user)
      fork = Factories.repository(user: user, upstream_repository: upstream)
      epic = Epic.create!(user: user, repository: upstream, title: "Cross-fork epic")
      job = Job.create!(user: user, repository: fork, epic: epic, issue_number: 3)
      expect(job.target_repository_id).to eq(upstream.id)
    end

    it "leaves target_repository_id nil when the fork's upstream differs from the epic's repository" do
      unrelated_upstream = Factories.repository(user: user)
      fork = Factories.repository(user: user, upstream_repository: unrelated_upstream)
      epic_repo = Factories.repository(user: user)
      epic = Epic.create!(user: user, repository: epic_repo, title: "Different upstream epic")
      job = Job.new(user: user, repository: fork, epic: epic, issue_number: 4)
      job.valid?
      expect(job.target_repository_id).to be_nil
    end
  end

  describe "epic_belongs_to_same_user_and_repository validation" do
    let(:user) { Factories.user }

    it "is valid when the epic is on the same repository" do
      repo = Factories.repository(user: user)
      epic = Epic.create!(user: user, repository: repo, title: "Same-repo epic")
      job = Job.new(user: user, repository: repo, epic: epic, issue_number: 7)
      expect(job).to be_valid
    end

    it "is valid when the epic is on the upstream of the job's fork repository" do
      upstream = Factories.repository(user: user)
      fork = Factories.repository(user: user, upstream_repository: upstream)
      epic = Epic.create!(user: user, repository: upstream, title: "Upstream epic")
      job = Job.new(user: user, repository: fork, epic: epic, issue_number: 8)
      expect(job).to be_valid
    end

    it "is invalid when the epic is on an unrelated repository" do
      repo = Factories.repository(user: user)
      other_repo = Factories.repository(user: user)
      epic = Epic.create!(user: user, repository: other_repo, title: "Unrelated epic")
      job = Job.new(user: user, repository: repo, epic: epic, issue_number: 9)
      expect(job).not_to be_valid
      expect(job.errors[:epic]).to include("must belong to the same repository or its upstream")
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

    it "does not auto-spawn a Run before triage advances" do
      ordinary = Job.create!(user: user, repository: repository, issue_number: 100)
      expect(ordinary).to be_triaging
      expect(ordinary.runs).to be_empty
    end
  end

  describe "epic_belongs_to_same_user_and_repository" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "allows a job on a fork to be associated with an epic on the upstream repo" do
      upstream = Factories.repository(user: user, owner: "upstream", name: "lib")
      fork = Factories.repository(user: user, owner: "acme", name: "lib-fork", upstream_repository: upstream)
      epic = Factories.epic(user: user, repository: upstream)

      job = Factories.job_record(user: user, repository: fork, epic: epic, issue_number: 55)
      expect(job.errors[:epic]).to be_empty
    end

    it "rejects a job whose repository is unrelated to the epic's repository" do
      other_repo = Factories.repository(user: user, owner: "acme", name: "other")
      epic = Factories.epic(user: user, repository: repository)

      job = Job.new(user: user, owner_user: user, repository: other_repo, epic: epic, issue_number: 56, kind: "issue")
      job.valid?
      expect(job.errors[:epic]).to include("must belong to the same repository or its upstream")
    end
  end

  describe "Coding Mode lock" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_session) { ChatSession.create!(user: user) }

    def enable_coding_mode!(enabled: true)
      feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
        record.category = "Labs"
        record.name = "Coding Mode"
      end
      feature.update!(enabled: enabled)
    end

    describe "#locked_by_coding_mode?" do
      it "returns false when linked_chat_id is nil" do
        job = Factories.job_record(user: user, repository: repository, state: "queued")
        expect(job.locked_by_coding_mode?).to be(false)
      end

      it "returns true when linked_chat_id is set" do
        job = Factories.job_record(user: user, repository: repository, state: "queued")
        job.update!(linked_chat_id: chat_session.id)
        expect(job.locked_by_coding_mode?).to be(true)
      end
    end

    describe "#lock_for_coding_mode!" do
      it "transitions a queued job to coding state and sets linked_chat_id" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "queued")

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(true)
        expect(job.reload).to be_coding
        expect(job.linked_chat_id).to eq(chat_session.id)
      end

      it "transitions an implemented job to coding state" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "implemented")

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(true)
        expect(job.reload).to be_coding
      end

      it "unapproves an approved job before entering coding state" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "approved", approved_at: Time.current)

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(true)
        expect(job.reload).to be_coding
        expect(job.approved_at).to be_nil
      end

      it "returns false and does not change state when feature flag is off" do
        job = Factories.job_record(user: user, repository: repository, state: "queued")

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(false)
        expect(job.reload).to be_queued
        expect(job.linked_chat_id).to be_nil
      end

      it "returns false when already locked by a chat session" do
        enable_coding_mode!
        other_chat = ChatSession.create!(user: user)
        job = Factories.job_record(user: user, repository: repository, state: "queued")
        job.update!(linked_chat_id: other_chat.id)
        job.update!(state: "coding")

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(false)
        expect(job.reload.linked_chat_id).to eq(other_chat.id)
      end

      it "returns false for an incompatible state (e.g. running)" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "running")

        result = job.lock_for_coding_mode!(chat_session)

        expect(result).to be(false)
        expect(job.reload).to be_running
      end
    end

    describe "#cancel_new_coding_job!" do
      it "clears linked_chat_id and closes the job" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        result = job.cancel_new_coding_job!

        expect(result).not_to be(false)
        expect(job.reload).to be_closed
        expect(job.linked_chat_id).to be_nil
        expect(job.closure_reason).to eq("cancelled")
      end

      it "accepts a custom closure reason" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        job.cancel_new_coding_job!(reason: "replaced")

        expect(job.reload.closure_reason).to eq("replaced")
      end

      it "returns false when job is not in coding state" do
        job = Factories.job_record(user: user, repository: repository, state: "queued")

        expect(job.cancel_new_coding_job!).to be(false)
        expect(job.reload).to be_queued
      end
    end

    describe "#start_coding_handoff!" do
      it "releases the coding lock and fires a coding_handoff workflow" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        workflow = job.start_coding_handoff!

        expect(workflow).to be_a(Workflow)
        expect(workflow.trigger_kind).to eq("coding_handoff")
        expect(job.reload).not_to be_coding
        expect(job.linked_chat_id).to eq(chat_session.id)
      end

      it "returns false when job is not in coding state" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "implemented")

        expect(job.start_coding_handoff!).to be(false)
      end

      it "returns false when coding_mode feature is disabled" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        expect(job.start_coding_handoff!).to be(false)
        expect(job.reload).to be_coding
      end

      it "keeps linked_chat_id set so after_fail/after_success hooks can route to chat" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        job.start_coding_handoff!

        expect(job.reload.linked_chat_id).to eq(chat_session.id)
      end
    end

    describe "#revert_to_coding_mode!" do
      it "transitions a running job back to coding state" do
        job = Factories.job_record(user: user, repository: repository, state: "running",
                                   linked_chat_id: chat_session.id)

        expect(job.may_revert_to_coding_mode?).to be(true)
        job.revert_to_coding_mode!
        job.save!

        expect(job.reload).to be_coding
      end

      it "is not available from states other than running" do
        job = Factories.job_record(user: user, repository: repository, state: "implemented")
        expect(job.may_revert_to_coding_mode?).to be(false)
      end
    end

    describe "#release_coding_mode_takeover!" do
      it "clears linked_chat_id and returns the job to implemented" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        result = job.release_coding_mode_takeover!

        expect(result).to be(true)
        expect(job.reload).to be_implemented
        expect(job.linked_chat_id).to be_nil
      end

      it "drains queued workflows after releasing the lock" do
        enable_coding_mode!
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)
        workflow = Workflow.create!(job: job, trigger_kind: "pr_comment")
        step = Step.create!(workflow: workflow, kind: "respond", position: 0)

        job.release_coding_mode_takeover!

        expect(step.runs.reload.count).to eq(1)
      end

      it "returns false when job is not in coding state" do
        job = Factories.job_record(user: user, repository: repository, state: "implemented")

        expect(job.release_coding_mode_takeover!).to be(false)
        expect(job.reload).to be_implemented
      end
    end

    describe "#complete_coding_handoff!" do
      it "returns the job to implemented while keeping linked_chat_id" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)

        result = job.complete_coding_handoff!

        expect(result).to be(true)
        expect(job.reload).to be_implemented
        expect(job.linked_chat_id).to eq(chat_session.id)
      end

      it "cancels held initial workflows" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)
        initial_workflow = Workflow.create!(job: job, trigger_kind: "initial")
        Step.create!(workflow: initial_workflow, kind: "implement", position: 0)

        job.complete_coding_handoff!

        expect(initial_workflow.reload).to be_cancelled
      end

      it "does not cancel non-initial workflows" do
        job = Factories.job_record(user: user, repository: repository, state: "coding",
                                   linked_chat_id: chat_session.id)
        pr_comment_workflow = Workflow.create!(job: job, trigger_kind: "pr_comment")
        Step.create!(workflow: pr_comment_workflow, kind: "respond", position: 0)

        job.complete_coding_handoff!

        expect(pr_comment_workflow.reload).to be_queued
      end

      it "returns false when job is not in coding state" do
        job = Factories.job_record(user: user, repository: repository, state: "implemented")

        expect(job.complete_coding_handoff!).to be(false)
        expect(job.reload).to be_implemented
      end
    end
  end

  describe "urgent job closed callback" do
    let(:repository) { Factories.repository }
    let(:user) { repository.user }

    it "enqueues UrgentJobClosedJob when an urgent job closes" do
      job = Factories.job_record(user: user, repository: repository, priority: "urgent", state: "queued")
      clear_enqueued_jobs
      expect {
        job.close!
      }.to have_enqueued_job(UrgentJobClosedJob).with(job.repository_id)
    end

    it "does not enqueue UrgentJobClosedJob when a non-urgent job closes" do
      job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
      clear_enqueued_jobs
      expect {
        job.close!
      }.not_to have_enqueued_job(UrgentJobClosedJob)
    end
  end

  describe "insight max-threshold callback" do
    let(:repository) { Factories.repository }
    let(:user) { repository.user }

    def enable_agent_insights!
      feature = Feature.find_or_create_by!(slug: "agent_insights") do |f|
        f.category = "Labs"
        f.name = "Agent Insights"
      end
      feature.update!(enabled: true)
    end

    def enable_insight_config(max:)
      InsightScheduleConfig.create!(
        repository: repository,
        enabled: true,
        min_jobs_since_last_run: 1,
        max_jobs_since_last_run: max
      )
    end

    before do
      allow(InsightScheduler).to receive(:enqueue_if_idle!)
    end

    it "does not trigger when the agent_insights feature is off" do
      enable_insight_config(max: 2)
      Factories.job_record(user: user, repository: repository, state: "closed")
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "does not trigger when InsightScheduleConfig is absent" do
      enable_agent_insights!
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "does not trigger when InsightScheduleConfig is disabled" do
      enable_agent_insights!
      InsightScheduleConfig.create!(repository: repository, enabled: false, min_jobs_since_last_run: 1, max_jobs_since_last_run: 2)
      Factories.job_record(user: user, repository: repository, state: "closed")
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "does not trigger when count is below max" do
      enable_agent_insights!
      enable_insight_config(max: 5)
      3.times { Factories.job_record(user: user, repository: repository, state: "closed") }
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!  # 4 total closed, max=5
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "triggers when count reaches max" do
      enable_agent_insights!
      enable_insight_config(max: 3)
      2.times { Factories.job_record(user: user, repository: repository, state: "closed") }
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!  # 3 total closed, max=3
      expect(InsightScheduler).to have_received(:enqueue_if_idle!).with(repository)
    end

    it "triggers when count exceeds max" do
      enable_agent_insights!
      enable_insight_config(max: 3)
      4.times { Factories.job_record(user: user, repository: repository, state: "closed") }
      job = Factories.job_record(user: user, repository: repository, state: "queued")
      job.close!  # 5 total closed, max=3
      expect(InsightScheduler).to have_received(:enqueue_if_idle!).with(repository)
    end

    it "does not trigger when an agent_insight job closes" do
      enable_agent_insights!
      enable_insight_config(max: 2)
      insight_job = Factories.job_record(user: user, repository: repository,
                                         kind: "agent_insight", issue_number: nil,
                                         issue_title: "Insight analysis", state: "queued")
      insight_job.close!
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end
  end
end
