require "rails_helper"

RSpec.describe StepDispatcher do
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
  end

  describe ".advance_from" do
    it "creates a Run on the next runnable step" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)
      expect(s3.runs.count).to eq(0)  # not yet
    end

    it "skips cancelled steps and creates a Run on the first queued step beyond them" do
      s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      expect {
        described_class.advance_from(s1)
      }.to change { s3.runs.count }.by(1)
      expect(s2.runs.count).to eq(0)
    end

    it "transitions the Workflow to succeeded when no runnable step remains" do
      workflow.start!; workflow.save!
      s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      s3.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      described_class.advance_from(s1)
      expect(workflow.reload).to be_succeeded
    end

    it "transitions the Workflow to succeeded after the last step in the chain" do
      workflow.start!; workflow.save!
      described_class.advance_from(s3)  # last step — no next
      expect(workflow.reload).to be_succeeded
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

  describe ".fail_from", skip: "Pending: .fail_from + cancellation_reason + failure_reason were part of the dropped #332 design — see follow-up issue" do
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

    it "fails the workflow and cancels post-loop steps when grade exhausts the loop budget" do
      loop_wf = workflow_with_loop(max_iterations: 1)
      loop_wf.start!; loop_wf.save!
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")
      pr_open = loop_wf.steps.find_by!(kind: "pr_open")

      described_class.fail_from(grade)

      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to eq("loop_exhausted")
      expect(summarize.reload).to be_cancelled
      expect(summarize.cancellation_reason).to eq("loop_exhausted")
      expect(pr_open.reload).to be_cancelled
      expect(pr_open.cancellation_reason).to eq("loop_exhausted")
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

  describe "#handle_failed_step" do
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
        described_class.new(loop_workflow, advancing_from: grade).handle_failed_step
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
    it "fires StepDispatcher.handle_failed_step when a step transitions to failed" do
      s1.start!; s1.save!
      expect(described_class).to receive(:handle_failed_step).with(s1)
      s1.fail!; s1.save!
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
end
