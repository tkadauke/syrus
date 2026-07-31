require "rails_helper"

RSpec.describe StepDispatcher do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "summarize", position: 1) }
  let!(:s3) { Step.create!(workflow: workflow, kind: "pr_open",   position: 2) }

  before do
    s1.update!(next_step_id: s2.id)
    s2.update!(next_step_id: s3.id)
  end

  describe ".start_workflow" do
    it "creates a Run on the first step" do
      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
      expect(s1.runs.last.trigger_kind).to eq("initial")
      expect(s1.runs.last.agent_provider).to eq("claude")
    end

    it "copies the workflow agent_provider onto created Runs" do
      workflow.update!(agent_provider: "codex")
      described_class.start_workflow(workflow)
      expect(s1.runs.last.agent_provider).to eq("codex")
    end

    it "is idempotent — won't double-create a Run" do
      described_class.start_workflow(workflow)
      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
    end

    it "threads parent_session_id + prompt through to the first Run" do
      described_class.start_workflow(workflow, parent_session_id: "S-prior", prompt: "carry-over")
      run = s1.runs.last
      expect(run.parent_session_id).to eq("S-prior")
      expect(run.prompt).to eq("carry-over")
    end

    it "does not create a Run while dependencies are unsatisfied" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
    end

    it "warns when a non-rebase workflow is left queued by an unresolved stack dependency" do
      JobDependency.create!(
        job: job,
        source: "manual",
        unresolved_owner: job.repository.owner,
        unresolved_repo: job.repository.name,
        unresolved_number: 999
      )

      expect(Rails.logger).to receive(:warn).with(
        include(
          "[StepDispatcher] workflow #{workflow.id} (initial) left queued with 0 runs:",
          "stack_dependencies_not_ready",
          "job_id=#{job.id}"
        )
      )

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
      expect(workflow.reload).to be_queued
    end

    it "starts once dependencies are satisfied" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
      prerequisite.close_with_reason!("pr_merged")

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
    end

    context "when the job is locked by Coding Mode" do
      def enable_coding_mode!(enabled: true)
        feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
          record.category = "Labs"
          record.name = "Coding Mode"
        end
        feature.update!(enabled: enabled)
      end

      it "leaves the workflow queued and does not create a Run when the flag is on" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect {
          described_class.start_workflow(workflow)
        }.not_to change { Run.count }

        expect(workflow.reload).to be_queued
      end

      it "logs an info message when blocked by coding mode lock" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect(Rails.logger).to receive(:info).with(include("held", "in coding state"))
        described_class.start_workflow(workflow)
      end

      it "starts the workflow normally when the feature flag is off even if the job is in coding state" do
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect {
          described_class.start_workflow(workflow)
        }.to change { s1.runs.count }.by(1)
      end

      it "starts queued workflows after the lock is released via release_coding_mode_takeover!" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)
        described_class.start_workflow(workflow)
        expect(s1.runs.reload.count).to eq(0)

        job.release_coding_mode_takeover!

        expect(s1.runs.reload.count).to eq(1)
      end

      it "starts a new workflow after handoff even when linked_chat_id is preserved" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        # Simulate complete_coding_handoff!: job is now :implemented but
        # linked_chat_id is still set for grader routing.
        job.update!(state: "implemented")
        handoff_workflow = Workflow.create!(job: job, trigger_kind: "coding_handoff")
        step = Step.create!(workflow: handoff_workflow, kind: "grader_fanout", position: 0)

        expect {
          described_class.start_workflow(handoff_workflow)
        }.to change { step.runs.count }.by(1)
      end
    end

    it "cancels blocked rebase workflows instead of leaving them active with no Run" do
      prerequisite = Factories.job_record(repository: job.repository, issue_number: 99, state: "closed", closure_reason: "pr_closed")
      blocked_job = Factories.job_record(
        user: job.user,
        repository: job.repository,
        issue_number: 100,
        state: "approved",
        pr_number: 100,
        branch_name: "syrus/issue-100-#{job.id}"
      )
      JobDependency.create!(job: blocked_job, depends_on_job: prerequisite, source: "manual")
      rebase = Workflows::Rebase.instantiate(job: blocked_job)

      expect(RebaseWorkflowSelector.active_for_stack?(blocked_job)).to be(false)

      expect(Rails.logger).not_to receive(:warn).with(include("stack_dependencies_not_ready", "workflow #{rebase.id}"))

      expect {
        described_class.start_workflow(rebase)
      }.not_to change { Run.count }

      expect(rebase.reload).to be_cancelled
      expect(rebase.artifact("start_blocked_reason")).to eq("stack_dependencies_not_ready")
      expect(rebase.steps.pluck(:state).uniq).to eq([ "cancelled" ])
      expect(RebaseWorkflowSelector.active_for_stack?(blocked_job)).to be(false)
    end

    it "starts on an open dependency PR after resolving it as the stack parent" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "starts landing workflows when redundant transitive dependencies resolve to one stack parent" do
      epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
      root = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 97, state: "approved",
        branch_name: "syrus/issue-97", pr_number: 97
      )
      root.runs.create!(trigger_kind: "initial", agent_provider: root.agent_provider, head_sha: "a" * 40)
      middle = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 98, state: "approved",
        branch_name: "syrus/issue-98", pr_number: 98
      )
      middle.runs.create!(trigger_kind: "initial", agent_provider: middle.agent_provider, head_sha: "b" * 40)
      JobDependency.create!(job: middle, depends_on_job: root, source: "manual")
      landing_job = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 99, state: "approved",
        branch_name: "syrus/issue-99", pr_number: 99
      )
      JobDependency.create!(job: landing_job, depends_on_job: root, source: "manual")
      JobDependency.create!(job: landing_job, depends_on_job: middle, source: "manual")
      auto_merge = Workflows::AutoMerge.instantiate(job: landing_job)
      first_step = auto_merge.first_step

      expect {
        described_class.start_workflow(auto_merge)
      }.to change { first_step.runs.count }.by(1)

      expect(auto_merge.reload).not_to be_failed
      expect(auto_merge.failure_reason).to be_nil
      expect(landing_job.reload.parent_job).to eq(middle)
    end
  end

  describe ".advance_from" do
    it "creates a Run on the next runnable step" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)
      expect(s3.runs.count).to eq(0)  # not yet
    end

    it "skips test_plan without creating a Run when the plan artifact already exists" do
      test_plan = Step.create!(workflow: workflow, kind: "test_plan", position: 2)
      s3.update!(position: 3)
      s2.update!(next_step_id: test_plan.id)
      test_plan.update!(next_step_id: s3.id)
      workflow.set_artifact!("test_plan", { "steps" => [ "Run the tests" ], "notes" => nil })

      expect {
        described_class.advance_from(s2)
      }.to change { s3.runs.count }.by(1)

      expect(test_plan.reload).to be_succeeded
      expect(test_plan.runs.count).to eq(0)
      expect(test_plan.details).to include(
        "skipped" => true,
        "skip_reason" => "test_plan_already_submitted"
      )
    end

    it "skips cancelled steps and creates a Run on the first queued step beyond them" do
      Step.suppress_cancel_cascade do
        s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      end
      expect {
        described_class.advance_from(s1)
      }.to change { s3.runs.count }.by(1)
      expect(s2.runs.count).to eq(0)
    end

    it "transitions the Workflow to succeeded when no runnable step remains" do
      workflow.start!; workflow.save!
      Step.suppress_cancel_cascade do
        s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
        s3.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      end
      described_class.advance_from(s1)
      expect(workflow.reload).to be_succeeded
    end

    it "transitions the Workflow to succeeded after the last step in the chain" do
      workflow.start!; workflow.save!
      described_class.advance_from(s3)  # last step — no next
      expect(workflow.reload).to be_succeeded
    end

    it "does not finish the Workflow while another descendant Step or Run is still active" do
      workflow.start!
      workflow.save!
      s1.update_columns(state: "running", started_at: 1.minute.ago)
      run = s1.runs.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: 1.minute.ago, last_heartbeat_at: Time.current)
      s3.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      described_class.advance_from(s3)

      expect(workflow.reload).to be_running
      expect(WorkflowWorkspace).not_to have_received(:cleanup_for)
    end

    it "schedules a merge-state poll after a pending stacked auto-merge rebase push" do
      clear_enqueued_jobs
      job.repository.update!(auto_merge_enabled: true)
      job.update!(pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      pending = Workflows::AutoMerge.instantiate(job: job)
      pending.set_artifact!("pending_auto_merge", "waiting_for_parent")
      pending.cancel!
      pending.save!
      rebase = Workflow.create!(job: job, trigger_kind: "rebase")
      force_push = Step.create!(workflow: rebase, kind: "force_push", position: 0)
      rebase.start!; rebase.save!
      force_push.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      described_class.advance_from(force_push)

      expect(enqueued_jobs.any? { |entry| entry[:job] == PollMergeStateJob }).to be(true)
    end

    it "cascades stack child rebases after a force-push workflow succeeds" do
      clear_enqueued_jobs
      job.update!(state: "implemented", pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      child = Factories.job(repository: job.repository, issue_number: 43).tap do |child_job|
        JobDependency.create!(job: child_job, depends_on_job: job, source: "manual")
        child_job.update!(
          state: "implemented",
          parent_job: job,
          branch_name: "syrus/issue-43-#{child_job.id}",
          pr_number: 43
        )
        child_job.workflows.update_all(state: "succeeded")
      end
      rebase = Workflow.create!(job: job, trigger_kind: "rebase")
      force_push = Step.create!(workflow: rebase, kind: "force_push", position: 0)
      rebase.start!
      rebase.save!
      force_push.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect {
        described_class.advance_from(force_push)
      }.to change { child.reload.workflows.where(trigger_kind: "stack_rebase").count }.by(1)

      child_rebase = child.workflows.where(trigger_kind: "stack_rebase").last
      expect(child_rebase.artifact("rebase_base_branch")).to eq(job.branch_name)
      expect(enqueued_jobs.any? { |entry| entry[:job] == RunJob }).to be(true)
    end

    it "cascades stack child rebases after a recovered push workflow succeeds" do
      clear_enqueued_jobs
      job.update!(state: "implemented", pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      child = Factories.job(repository: job.repository, issue_number: 43).tap do |child_job|
        JobDependency.create!(job: child_job, depends_on_job: job, source: "manual")
        child_job.update!(
          state: "implemented",
          parent_job: job,
          branch_name: "syrus/issue-43-#{child_job.id}",
          pr_number: 43
        )
        child_job.workflows.update_all(state: "succeeded")
      end
      follow_up = Workflow.create!(job: job, trigger_kind: "pr_comment")
      push_after_rebase = Step.create!(workflow: follow_up, kind: "push_after_rebase", position: 0)
      follow_up.start!
      follow_up.save!
      push_after_rebase.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect {
        described_class.advance_from(push_after_rebase)
      }.to change { child.reload.workflows.where(trigger_kind: "stack_rebase").count }.by(1)

      child_rebase = child.workflows.where(trigger_kind: "stack_rebase").last
      expect(child_rebase.artifact("rebase_base_branch")).to eq(job.branch_name)
      expect(enqueued_jobs.any? { |entry| entry[:job] == RunJob }).to be(true)
    end

    it "advances a succeeded grade step to the post-loop step" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")

      expect {
        described_class.advance_from(grade)
      }.to change { summarize.runs.count }.by(1)
    end

    it "keeps workflows without loops on the existing linear path" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)

      expect(workflow.steps.where.not(loop_id: nil)).to be_empty
      expect(workflow.reload).to be_queued
    end
  end

  describe ".fail_from" do
    it "materializes the next loop iteration when grade fails with budget remaining" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      implement = loop_wf.steps.find_by!(kind: "implement", iteration: 1)
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")
      run = implement.runs.create!(job: job, trigger_kind: "manual")
      ClaudeSession.create!(run: run, session_id: "S-iter-1", transcript_jsonl: "{}\n")

      expect {
        described_class.fail_from(grade)
      }.to change { loop_wf.steps.count }.by(2)
       .and change { Run.count }.by(1)

      new_steps = loop_wf.reload.steps.where(loop_id: grade.loop_id, iteration: 2).order(:position).to_a
      expect(new_steps.map(&:kind)).to eq(%w[ implement grade ])
      expect(grade.reload.next_step).to eq(new_steps.first)
      expect(new_steps.first.next_step).to eq(new_steps.last)
      expect(new_steps.last.next_step).to eq(summarize)
      expect(new_steps.first.runs.last.parent_session_id).to eq("S-iter-1")
      expect(new_steps.first.runs.last.iteration).to eq(2)
    end

    it "spends the loop budget before failing the workflow after repeated grade failures" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 1))
      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 2))
      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2, 3 ])

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 3))
      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to eq("loop_exhausted_after_grader_failure")
      expect(loop_wf.failure_count).to eq(1)
    end

    it "fails the workflow and cancels post-loop steps when grade exhausts the loop budget" do
      loop_wf = workflow_with_loop(max_iterations: 1)
      loop_wf.start!; loop_wf.save!
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")
      pr_open = loop_wf.steps.find_by!(kind: "pr_open")

      described_class.fail_from(grade)

      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to eq("loop_exhausted_after_grader_failure")
      expect(loop_wf.failure_count).to eq(1)
      expect(summarize.reload).to be_cancelled
      expect(summarize.cancellation_reason).to eq("loop_exhausted_after_grader_failure")
      expect(pr_open.reload).to be_cancelled
      expect(pr_open.cancellation_reason).to eq("loop_exhausted_after_grader_failure")
    end

    it "hard-fails the workflow when a non-grade step inside a loop fails" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!
      implement = loop_wf.steps.find_by!(kind: "implement", iteration: 1)

      expect {
        described_class.fail_from(implement)
      }.not_to change { loop_wf.steps.count }

      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to be_nil
    end
  end

  describe ".fail_from" do
    it "inserts the next loop iteration before continuation steps" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::Loop.new(max_iterations: 2, steps: [ :implement, :grade ]),
              :summarize,
              :pr_open

        def self.trigger_kind = "initial"
      end
      loop_workflow = workflow_class.instantiate(job: job)
      implement, grade, summarize, pr_open = loop_workflow.steps.order(:position)

      expect {
        described_class.fail_from(grade)
      }.to change { Run.count }.by(1)

      loop_id = implement.loop_id
      expect(loop_workflow.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "implement", 0, 1, loop_id ],
        [ "grade", 1, 1, loop_id ],
        [ "implement", 2, 2, loop_id ],
        [ "grade", 3, 2, loop_id ],
        [ "summarize", 4, 1, nil ],
        [ "pr_open", 5, 1, nil ]
      ])
      expect(grade.reload.next_step).to eq(loop_workflow.steps.find_by!(kind: "implement", iteration: 2))
      expect(loop_workflow.steps.find_by!(kind: "grade", iteration: 2).next_step).to eq(summarize)
      expect(pr_open.reload.position).to eq(5)
    end

    it "inserts retry_until repair steps only after a failed check-only first iteration" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 2,
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :push,
              :auto_merge

        def self.trigger_kind = "auto_merge"
      end
      retry_workflow = workflow_class.instantiate(job: job)
      grader_fanout, grader_collect, push, auto_merge = retry_workflow.steps.order(:position)

      expect {
        described_class.fail_from(grader_collect)
      }.to change { Run.count }.by(1)

      loop_id = grader_fanout.loop_id
      expect(retry_workflow.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "grader_fanout", 0, 1, loop_id ],
        [ "grader_collect", 1, 1, loop_id ],
        [ "landing_fix", 2, 2, loop_id ],
        [ "grader_fanout", 3, 2, loop_id ],
        [ "grader_collect", 4, 2, loop_id ],
        [ "push", 5, 1, nil ],
        [ "auto_merge", 6, 1, nil ]
      ])
      expect(grader_collect.reload.next_step).to eq(retry_workflow.steps.find_by!(kind: "landing_fix", iteration: 2))
      expect(retry_workflow.steps.find_by!(kind: "grader_collect", iteration: 2).next_step).to eq(push)
      expect(auto_merge.reload.position).to eq(6)
    end

    it "advances retry_until check-only first iteration without materializing repair when checks pass" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 2,
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :push

        def self.trigger_kind = "auto_merge"
      end
      retry_workflow = workflow_class.instantiate(job: job)
      grader_collect = retry_workflow.steps.find_by!(kind: "grader_collect")
      push = retry_workflow.steps.find_by!(kind: "push")
      original_step_count = retry_workflow.steps.count

      expect {
        described_class.advance_from(grader_collect)
      }.to change { push.runs.count }.by(1)

      expect(retry_workflow.steps.count).to eq(original_step_count)
      expect(push.runs.last.iteration).to eq(1)
      expect(retry_workflow.steps.find_by(kind: "landing_fix")).to be_nil
    end

    it "expands the merge_train_land failure branch when base moved" do
      try_workflow = workflow_with_try_merge_train_land_branch
      land = try_workflow.steps.find_by!(kind: "merge_train_land")
      land.update!(details: land.details.merge("failure_code" => Steps::MergeTrainLand::BaseMoved::FAILURE_CODE))

      expect {
        described_class.fail_from(land)
      }.to change { try_workflow.steps.count }.by(4)
        .and change { Run.count }.by(1)

      branch_steps = try_workflow.reload.steps.order(:position).to_a
      loop_id = try_workflow.steps.find_by!(kind: "grader_collect").loop_id

      expect(branch_steps.map { |s| [ s.kind, s.position, s.iteration, s.loop_id ] }).to eq([
        [ "merge_train_build",            0, 1, nil ],
        [ "merge_train_land",             1, 1, nil ],
        [ "merge_train_rebase",           2, 1, nil ],
        [ "grader_fanout",                3, 1, loop_id ],
        [ "grader_collect",               4, 1, loop_id ],
        [ "merge_train_land_after_rebase", 5, 1, nil ]
      ])
      expect(land.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "merge_train_rebase"))
      expect(try_workflow.steps.find_by!(kind: "merge_train_land_after_rebase").next_step).to be_nil
      expect(try_workflow.steps.find_by!(kind: "merge_train_rebase").runs.last.trigger_kind).to eq("merge_train")
      expect(land.details).to include(
        "try_branch_expanded" => true,
        "try_branch_failure_code" => Steps::MergeTrainLand::BaseMoved::FAILURE_CODE
      )
    end

    it "expands a Try failure branch before the continuation step" do
      try_workflow = workflow_with_try_push_branch
      push = try_workflow.steps.find_by!(kind: "push")
      continuation = try_workflow.steps.find_by!(kind: "auto_merge")
      push.update!(details: push.details.merge("failure_code" => "remote_branch_advanced_rebase_conflict"))

      expect {
        described_class.fail_from(push)
      }.to change { try_workflow.steps.count }.by(4)
        .and change { Run.count }.by(1)

      branch_steps = try_workflow.reload.steps.order(:position).to_a
      loop_id = try_workflow.steps.find_by!(kind: "grader_collect").loop_id

      expect(branch_steps.map { |step| [ step.kind, step.position, step.iteration, step.loop_id ] }).to eq([
        [ "summarize_amend", 0, 1, nil ],
        [ "push", 1, 1, nil ],
        [ "push_agent_rebase", 2, 1, nil ],
        [ "grader_fanout", 3, 1, loop_id ],
        [ "grader_collect", 4, 1, loop_id ],
        [ "push_after_rebase", 5, 1, nil ],
        [ "auto_merge", 6, 1, nil ]
      ])
      expect(push.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "push_agent_rebase"))
      expect(try_workflow.steps.find_by!(kind: "push_after_rebase").next_step).to eq(continuation)
      expect(try_workflow.steps.find_by!(kind: "push_agent_rebase").runs.last.trigger_kind).to eq("pr_comment")
      expect(push.details).to include(
        "try_branch_expanded" => true,
        "try_branch_failure_code" => "remote_branch_advanced_rebase_conflict"
      )

      expect {
        described_class.fail_from(push.reload)
      }.not_to change { try_workflow.steps.count }
    end

    it "runs retry_until repair iterations inside an expanded Try branch" do
      try_workflow = workflow_with_try_push_branch
      push = try_workflow.steps.find_by!(kind: "push")
      push.update!(details: push.details.merge("failure_code" => "remote_branch_advanced_rebase_conflict"))
      described_class.fail_from(push)

      grader_collect = try_workflow.reload.steps.find_by!(kind: "grader_collect", iteration: 1)
      push_after_rebase = try_workflow.steps.find_by!(kind: "push_after_rebase")

      expect {
        described_class.fail_from(grader_collect)
      }.to change { try_workflow.steps.count }.by(3)
        .and change { Run.count }.by(1)

      loop_id = grader_collect.loop_id
      expect(try_workflow.reload.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "summarize_amend", 0, 1, nil ],
        [ "push", 1, 1, nil ],
        [ "push_agent_rebase", 2, 1, nil ],
        [ "grader_fanout", 3, 1, loop_id ],
        [ "grader_collect", 4, 1, loop_id ],
        [ "landing_fix", 5, 2, loop_id ],
        [ "grader_fanout", 6, 2, loop_id ],
        [ "grader_collect", 7, 2, loop_id ],
        [ "push_after_rebase", 8, 1, nil ],
        [ "auto_merge", 9, 1, nil ]
      ])
      expect(grader_collect.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "landing_fix", iteration: 2))
      expect(try_workflow.steps.find_by!(kind: "grader_collect", iteration: 2).next_step).to eq(push_after_rebase)
      expect(try_workflow.steps.find_by!(kind: "landing_fix", iteration: 2).runs.last).to be_present
    end

    it "exits an exhausted adversarial review loop to the final implement step" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 1)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      ClaudeSession.create!(
        run: implement.runs.create!(job: job, trigger_kind: "initial"),
        session_id: "implement-1",
        transcript_jsonl: "{}\n"
      )

      original_step_count = review_workflow.steps.count

      expect {
        described_class.advance_from(review)
      }.to change { final_implement.runs.count }.by(1)

      expect(review_workflow.steps.count).to eq(original_step_count)
      expect(final_implement.runs.last.parent_session_id).to be_nil
    end

    it "materializes the next adversarial review iteration before the final implement step" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      ClaudeSession.create!(
        run: implement.runs.create!(job: job, trigger_kind: "initial"),
        session_id: "implement-1",
        transcript_jsonl: "{}\n"
      )

      expect {
        described_class.advance_from(review)
      }.to change { review_workflow.steps.count }.by(2)
        .and change { Run.count }.by(1)

      new_steps = review_workflow.reload.steps.where(loop_id: review.loop_id, iteration: 2).order(:position).to_a
      expect(new_steps.map(&:kind)).to eq(%w[ implement adversarial_review ])
      expect(review.reload.next_step).to eq(new_steps.first)
      expect(new_steps.last.next_step).to eq(final_implement)
      expect(new_steps.first.runs.last.parent_session_id).to eq("implement-1")
    end

    it "uses the implement session, not the reviewer session, for adversarial loop repair continuity" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      implement_run = implement.runs.create!(job: job, trigger_kind: "initial")
      review_run = review.runs.create!(job: job, trigger_kind: "initial")
      ClaudeSession.create!(run: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")
      ClaudeSession.create!(run: review_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      dispatcher = described_class.new(review_workflow, advancing_from: review)

      expect(dispatcher.send(:prior_iteration_session_id)).to eq("implementer-session")
    end

    it "skips final implement and enqueues grader_fanout when reviewer approves mid-loop (iteration 1 of 2)" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      grader_fanout = review_workflow.steps.find_by!(kind: "grader_fanout")

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "LGTM", "verdict" => "approved" }
      ])

      original_step_count = review_workflow.steps.count

      expect {
        described_class.advance_from(review)
      }.to change { grader_fanout.runs.count }.by(1)

      expect(review_workflow.reload.steps.count).to eq(original_step_count)
      expect(final_implement.reload).to be_cancelled
      expect(final_implement.cancellation_reason).to eq("adversarial_review_approved")
      expect(grader_fanout.reload).to be_queued
      expect(review_workflow.steps.find_by!(kind: "grader_collect")).to be_queued
      expect(review_workflow.reload).not_to be_cancelled
      expect(review_workflow.steps.where(loop_id: review.loop_id, iteration: 2)).to be_empty
    end

    it "skips final implement and enqueues grader_fanout when reviewer approves at last iteration (iteration 2 of 2)" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review1 = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review1.loop_id).sole
      grader_fanout = review_workflow.steps.find_by!(kind: "grader_fanout")

      # Materialize the second loop iteration (as enqueue_next_loop_iteration! would)
      implement2 = Step.create!(workflow: review_workflow, kind: "implement", position: 3,
                                iteration: 2, loop_id: review1.loop_id)
      review2 = Step.create!(workflow: review_workflow, kind: "adversarial_review", position: 4,
                              iteration: 2, loop_id: review1.loop_id)
      review_workflow.steps.where("position >= 3").where.not(id: [ implement2.id, review2.id ])
                     .update_all("position = position + 2")
      review1.update!(next_step_id: implement2.id)
      implement2.update!(next_step_id: review2.id)
      review2.update!(next_step_id: final_implement.id)

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "needs work", "verdict" => "needs_work" },
        { "iteration" => 2, "critique" => "LGTM", "verdict" => "approved" }
      ])

      original_step_count = review_workflow.reload.steps.count

      expect {
        described_class.advance_from(review2)
      }.to change { grader_fanout.runs.count }.by(1)

      expect(review_workflow.reload.steps.count).to eq(original_step_count)
      expect(final_implement.reload).to be_cancelled
      expect(final_implement.cancellation_reason).to eq("adversarial_review_approved")
      expect(grader_fanout.reload).to be_queued
      expect(review_workflow.steps.find_by!(kind: "grader_collect")).to be_queued
      expect(review_workflow.reload).not_to be_cancelled
    end

    it "does not skip final implement when verdict is needs_work with iterations remaining" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "needs more work", "verdict" => "needs_work" }
      ])

      expect {
        described_class.advance_from(review)
      }.to change { review_workflow.steps.count }.by(2)

      expect(final_implement.runs.reload).to be_empty
      expect(final_implement.reload).to be_queued
    end

    it "falls through to final implement when verdict is needs_work and iterations exhausted" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "still needs work", "verdict" => "needs_work" }
      ])

      expect {
        described_class.advance_from(review)
      }.to change { final_implement.runs.count }.by(1)

      expect(final_implement.reload).to be_queued
    end
  end

  describe "Step#after_update_commit advance integration" do
    it "fires StepDispatcher.advance_from when a step transitions to succeeded" do
      run = s1.runs.create!(job: job, trigger_kind: "initial")
      run.start!; run.save!
      s1.start!; s1.save!
      expect(described_class).to receive(:advance_from).with(s1)
      s1.succeed!; s1.save!
    end
  end

  describe "Step#after_update_commit fail integration" do
    it "fires StepDispatcher.fail_from when a step transitions to failed" do
      s1.start!; s1.save!
      expect(described_class).to receive(:fail_from).with(s1)
      s1.fail!; s1.save!
    end

    it "routes failed loop grade steps through the dispatcher without failing early" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)

      grade.start!; grade.save!
      grade.fail!; grade.save!

      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.find_by(kind: "implement", iteration: 2)).to be_present
    end
  end

  def workflow_with_loop(max_iterations:)
    Workflow.create!(
      job: job,
      trigger_kind: "manual",
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        { "type" => "loop", "max_iterations" => max_iterations, "steps" => %w[ implement grade ] },
        { "type" => "step", "kind" => "summarize" },
        { "type" => "step", "kind" => "pr_open" }
      ]
    ).tap do |wf|
      prepare = Step.create!(workflow: wf, kind: "prepare", position: 0)
      implement = Step.create!(workflow: wf, kind: "implement", position: 1, iteration: 1, loop_id: "loop-a")
      grade = Step.create!(workflow: wf, kind: "grade", position: 2, iteration: 1, loop_id: "loop-a")
      summarize = Step.create!(workflow: wf, kind: "summarize", position: 3)
      pr_open = Step.create!(workflow: wf, kind: "pr_open", position: 4)
      prepare.update!(next_step_id: implement.id)
      implement.update!(next_step_id: grade.id)
      grade.update!(next_step_id: summarize.id)
      summarize.update!(next_step_id: pr_open.id)
    end
  end

  def workflow_with_adversarial_review_loop(max_iterations:)
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        { "type" => "loop", "max_iterations" => max_iterations, "steps" => %w[ implement adversarial_review ] },
        {
          "type" => "retry_until",
          "max_iterations" => 1,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        }
      ]
    ).tap do |wf|
      prepare = Step.create!(workflow: wf, kind: "prepare", position: 0)
      implement = Step.create!(workflow: wf, kind: "implement", position: 1, iteration: 1, loop_id: "review-loop")
      review = Step.create!(workflow: wf, kind: "adversarial_review", position: 2, iteration: 1, loop_id: "review-loop")
      final_implement = Step.create!(workflow: wf, kind: "implement", position: 3, iteration: 1, loop_id: "grade-loop")
      grader_fanout = Step.create!(workflow: wf, kind: "grader_fanout", position: 4, iteration: 1, loop_id: "grade-loop")
      grader_collect = Step.create!(workflow: wf, kind: "grader_collect", position: 5, iteration: 1, loop_id: "grade-loop")
      prepare.update!(next_step_id: implement.id)
      implement.update!(next_step_id: review.id)
      review.update!(next_step_id: final_implement.id)
      final_implement.update!(next_step_id: grader_fanout.id)
      grader_fanout.update!(next_step_id: grader_collect.id)
    end
  end

  def workflow_with_try_merge_train_land_branch
    try_id = "try-merge-train-land"
    Workflow.create!(
      job: job,
      trigger_kind: "merge_train",
      chain_template: [
        { "type" => "step", "kind" => "merge_train_build" },
        {
          "type" => "try",
          "id" => try_id,
          "step" => "merge_train_land",
          "on_failure" => {
            Steps::MergeTrainLand::BaseMoved::FAILURE_CODE => [
              { "type" => "step", "kind" => "merge_train_rebase" },
              {
                "type" => "retry_until",
                "max_iterations" => 2,
                "repair" => %w[ landing_fix ],
                "check" => %w[ grader_fanout grader_collect ],
                "repair_first" => false
              },
              { "type" => "step", "kind" => "merge_train_land_after_rebase" }
            ]
          }
        }
      ]
    ).tap do |wf|
      build = Step.create!(workflow: wf, kind: "merge_train_build", position: 0)
      land  = Step.create!(workflow: wf, kind: "merge_train_land", position: 1, details: { "try_id" => try_id })
      build.update!(next_step_id: land.id)
    end
  end

  def workflow_with_try_push_branch
    try_id = "try-push"
    Workflow.create!(
      job: job,
      trigger_kind: "pr_comment",
      chain_template: [
        { "type" => "step", "kind" => "summarize_amend" },
        {
          "type" => "try",
          "id" => try_id,
          "step" => "push",
          "on_failure" => {
            "remote_branch_advanced_rebase_conflict" => [
              { "type" => "step", "kind" => "push_agent_rebase" },
              {
                "type" => "retry_until",
                "max_iterations" => 2,
                "repair" => %w[ landing_fix ],
                "check" => %w[ grader_fanout grader_collect ],
                "repair_first" => false
              },
              { "type" => "step", "kind" => "push_after_rebase" }
            ]
          }
        },
        { "type" => "step", "kind" => "auto_merge" }
      ]
    ).tap do |wf|
      summarize = Step.create!(workflow: wf, kind: "summarize_amend", position: 0)
      push = Step.create!(workflow: wf, kind: "push", position: 1, details: { "try_id" => try_id })
      auto_merge = Step.create!(workflow: wf, kind: "auto_merge", position: 2)
      summarize.update!(next_step_id: push.id)
      push.update!(next_step_id: auto_merge.id)
    end
  end
end

RSpec.describe StepDispatcher, "urgent_blocking gate" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  def create_urgent_job!(state: "queued")
    Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      priority: "urgent",
      state: state
    )
  end

  it "does not block when no urgent jobs exist in the repository" do
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "blocks non-urgent workflows when an open urgent job exists" do
    create_urgent_job!
    expect {
      described_class.start_workflow(workflow)
    }.not_to change { Run.count }
    expect(workflow.reload).to be_queued
  end

  it "records urgent_job_active as the block reason" do
    create_urgent_job!
    described_class.start_workflow(workflow)
    expect(workflow.reload.artifact("start_blocked_reason")).to eq("urgent_job_active")
  end

  it "logs a warning when blocked by urgent job" do
    create_urgent_job!
    expect(Rails.logger).to receive(:warn).with(include("urgent_job_active"))
    described_class.start_workflow(workflow)
  end

  it "backs off repeated urgent-blocked starts" do
    create_urgent_job!
    travel_to(Time.zone.parse("2026-07-15 12:00:00 UTC")) do
      expect(Rails.logger).to receive(:warn).once.with(include("urgent_job_active"))

      described_class.start_workflow(workflow)
      next_check_at = workflow.reload.artifact("start_blocked_next_check_at")

      described_class.start_workflow(workflow)

      expect(workflow.reload.artifact("start_blocked_reason")).to eq("urgent_job_active")
      expect(workflow.artifact("start_blocked_next_check_at")).to eq(next_check_at)
    end
  end

  it "does not block urgent workflows even when other urgent jobs exist" do
    create_urgent_job!
    job_model.update_columns(priority: "urgent")

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when the formerly urgent job is now closed" do
    create_urgent_job!(state: "closed")

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "clears the urgent_job_active block reason when no longer blocked" do
    create_urgent_job!(state: "closed")
    workflow.update!(artifacts: { "start_blocked_reason" => "urgent_job_active" })

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end
end

RSpec.describe StepDispatcher, "main_health queue gate" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  def break_main!
    job_model.repository.update!(ci_health: "broken", landing_paused: true)
  end

  it "does not create a Run when the repository main_health is broken and landing is paused" do
    break_main!
    expect {
      described_class.start_workflow(workflow)
    }.not_to change { Run.count }
    expect(workflow.reload).to be_queued
  end

  it "logs a warning when main is broken and the workflow is left queued" do
    break_main!
    expect(Rails.logger).to receive(:warn).with(include("main_branch_broken"))
    described_class.start_workflow(workflow)
  end

  it "backs off repeated main-health blocked starts" do
    break_main!
    travel_to(Time.zone.parse("2026-07-15 12:00:00 UTC")) do
      expect(Rails.logger).to receive(:warn).once.with(include("main_branch_broken"))

      described_class.start_workflow(workflow)
      next_check_at = workflow.reload.artifact("start_blocked_next_check_at")

      described_class.start_workflow(workflow)

      expect(workflow.reload.artifact("start_blocked_reason")).to eq("main_branch_broken")
      expect(workflow.artifact("start_blocked_next_check_at")).to eq(next_check_at)
    end
  end

  it "starts the workflow when broken main has been manually unpaused" do
    job_model.repository.update!(ci_health: "broken", landing_paused: false)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when landing is paused and main_health is inconclusive" do
    job_model.repository.update!(ci_health: "not_configured", grader_health: "inconclusive", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when landing is paused and main_health is unknown" do
    job_model.repository.update!(ci_health: "unknown", grader_health: "unknown", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when main branch health checking is disabled" do
    job_model.repository.update!(main_branch_health_enabled: false, ci_health: "broken", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow normally when main_health is healthy" do
    job_model.repository.update!(ci_health: "healthy", grader_health: "healthy", landing_paused: true)
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow normally when main_health is unknown (default)" do
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "does not block rebase workflows even when main is broken" do
    break_main!
    rebase_workflow = Workflow.create!(job: job_model, trigger_kind: "rebase")
    rs1 = Step.create!(workflow: rebase_workflow, kind: "auto_rebase", position: 0)

    expect {
      described_class.start_workflow(rebase_workflow)
    }.to change { rs1.runs.count }.by(1)
  end

  it "does not block stack_rebase workflows even when main is broken" do
    break_main!
    sr_workflow = Workflow.create!(job: job_model, trigger_kind: "stack_rebase")
    rs1 = Step.create!(workflow: sr_workflow, kind: "stack_auto_rebase", position: 0)

    expect {
      described_class.start_workflow(sr_workflow)
    }.to change { rs1.runs.count }.by(1)
  end

  it "does not block a fix-main direct job's initial workflow even when main is broken" do
    break_main!
    fix_job = Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      kind: "direct",
      issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
      issue_number: nil,
      state: "queued"
    )
    fix_workflow = Workflow.create!(job: fix_job, trigger_kind: "initial")
    fix_step = Step.create!(workflow: fix_workflow, kind: "implement", position: 0)

    expect {
      described_class.start_workflow(fix_workflow)
    }.to change { fix_step.runs.count }.by(1)
  end
end

RSpec.describe StepDispatcher, "stack_dependencies_not_ready block reason" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  it "records stack_dependencies_not_ready as the block reason on a non-rebase workflow" do
    prerequisite = Factories.job(repository: job_model.repository, issue_number: 99)
    JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("stack_dependencies_not_ready")
  end

  it "clears stack_dependencies_not_ready when the dependency becomes satisfied" do
    prerequisite = Factories.job(repository: job_model.repository, issue_number: 99)
    JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")
    workflow.update!(artifacts: { "start_blocked_reason" => "stack_dependencies_not_ready" })

    prerequisite.close_with_reason!("pr_merged")
    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  it "does not record the block reason on a rebase workflow (rebase is cancelled instead)" do
    prerequisite = Factories.job_record(repository: job_model.repository, issue_number: 99, state: "closed", closure_reason: "pr_closed")
    blocked_job = Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      issue_number: 100,
      state: "approved",
      pr_number: 100,
      branch_name: "syrus/issue-100-#{job_model.id}"
    )
    JobDependency.create!(job: blocked_job, depends_on_job: prerequisite, source: "manual")
    rebase = Workflows::Rebase.instantiate(job: blocked_job)

    described_class.start_workflow(rebase)

    expect(rebase.reload).to be_cancelled
  end
end

RSpec.describe StepDispatcher, "job_not_ready_for_execution block reason" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  it "records job_not_ready_for_execution when the job is invalid" do
    job_model.update!(validity: "duplicate")

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("job_not_ready_for_execution")
  end

  it "clears job_not_ready_for_execution when the job becomes valid" do
    job_model.update!(validity: "duplicate")
    workflow.update!(artifacts: { "start_blocked_reason" => "job_not_ready_for_execution" })

    job_model.update!(validity: "valid")
    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end
end
