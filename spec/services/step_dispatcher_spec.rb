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
end
