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

    it "starts once dependencies are satisfied" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
      prerequisite.close_with_reason!("pr_merged")

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
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
  end

  describe ".advance_from" do
    it "creates a Run on the next runnable step" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)
      expect(s3.runs.count).to eq(0)  # not yet
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
      }.to change { child.reload.workflows.where(trigger_kind: "rebase").count }.by(1)

      child_rebase = child.workflows.where(trigger_kind: "rebase").last
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

    it "routes successful adversarial_review steps through loop iteration handling" do
      review_workflow = workflow_with_adversarial_loop(max_iterations: 2)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)

      expect_any_instance_of(described_class).to receive(:handle_loop_iteration).and_call_original

      expect {
        described_class.advance_from(review)
      }.to change { review_workflow.steps.count }.by(2)
    end

    it "materializes the next adversarial loop iteration before the final implement" do
      review_workflow = workflow_with_adversarial_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review.next_step
      run = implement.runs.create!(job: job, trigger_kind: "initial")
      ClaudeSession.create!(resumable: run, session_id: "implementer-session", transcript_jsonl: "{}\n")

      expect {
        described_class.advance_from(review)
      }.to change { Run.count }.by(1)

      loop_id = implement.loop_id
      expect(review_workflow.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "prepare", 0, 1, nil ],
        [ "implement", 1, 1, loop_id ],
        [ "adversarial_review", 2, 1, loop_id ],
        [ "implement", 3, 2, loop_id ],
        [ "adversarial_review", 4, 2, loop_id ],
        [ "implement", 5, 1, nil ],
        [ "implement", 6, 1, "grade-loop" ],
        [ "grader_fanout", 7, 1, "grade-loop" ],
        [ "grader_collect", 8, 1, "grade-loop" ],
        [ "summarize", 9, 1, nil ],
        [ "pr_open", 10, 1, nil ]
      ])
      expect(review.reload.next_step).to eq(review_workflow.steps.find_by!(kind: "implement", iteration: 2, loop_id: loop_id))
      expect(review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 2).next_step).to eq(final_implement)
      expect(final_implement.reload.position).to eq(5)
      expect(review.next_step.runs.last.parent_session_id).to eq("implementer-session")
    end

    it "advances from the exhausted adversarial loop to the standalone final implement" do
      review_workflow = workflow_with_adversarial_loop(max_iterations: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review.next_step
      review.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect {
        described_class.advance_from(review)
      }.to change { final_implement.runs.count }.by(1)

      expect(review_workflow.reload).to be_queued
      expect(final_implement.runs.last.iteration).to eq(1)
    end

    it "uses the implement session, not the reviewer session, for adversarial loop repair continuity" do
      review_workflow = workflow_with_adversarial_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      implement_run = implement.runs.create!(job: job, trigger_kind: "initial")
      review_run = review.runs.create!(job: job, trigger_kind: "initial")
      ClaudeSession.create!(resumable: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")
      ClaudeSession.create!(resumable: review_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      dispatcher = described_class.new(review_workflow, advancing_from: review)

      expect(dispatcher.send(:prior_iteration_session_id)).to eq("implementer-session")
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

  def workflow_with_adversarial_loop(max_iterations:)
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        {
          "type" => "retry_until",
          "max_iterations" => max_iterations,
          "repair" => %w[ implement ],
          "check" => %w[ adversarial_review ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "implement" },
        {
          "type" => "retry_until",
          "max_iterations" => 1,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "summarize" },
        { "type" => "step", "kind" => "pr_open" }
      ]
    ).tap do |wf|
      prepare = Step.create!(workflow: wf, kind: "prepare", position: 0)
      implement = Step.create!(workflow: wf, kind: "implement", position: 1, iteration: 1, loop_id: "review-loop")
      review = Step.create!(workflow: wf, kind: "adversarial_review", position: 2, iteration: 1, loop_id: "review-loop")
      final_implement = Step.create!(workflow: wf, kind: "implement", position: 3)
      grade_implement = Step.create!(workflow: wf, kind: "implement", position: 4, iteration: 1, loop_id: "grade-loop")
      grader_fanout = Step.create!(workflow: wf, kind: "grader_fanout", position: 5, iteration: 1, loop_id: "grade-loop")
      grader_collect = Step.create!(workflow: wf, kind: "grader_collect", position: 6, iteration: 1, loop_id: "grade-loop")
      summarize = Step.create!(workflow: wf, kind: "summarize", position: 7)
      pr_open = Step.create!(workflow: wf, kind: "pr_open", position: 8)
      prepare.update!(next_step_id: implement.id)
      implement.update!(next_step_id: review.id)
      review.update!(next_step_id: final_implement.id)
      final_implement.update!(next_step_id: grade_implement.id)
      grade_implement.update!(next_step_id: grader_fanout.id)
      grader_fanout.update!(next_step_id: grader_collect.id)
      grader_collect.update!(next_step_id: summarize.id)
      summarize.update!(next_step_id: pr_open.id)
    end
  end
end
