require "rails_helper"

RSpec.describe "workflow ordering" do
  describe "Job#workflows" do
    it "orders same-timestamp workflows by id" do
      job = Factories.job_record(state: "running")
      timestamp = Time.current.change(usec: 0)
      older_workflow = Workflow.create!(job: job, trigger_kind: "initial", created_at: timestamp, updated_at: timestamp)
      newer_workflow = Workflow.create!(job: job, trigger_kind: "retry", created_at: timestamp, updated_at: timestamp)

      expect(job.reload.workflows.to_a).to eq([ older_workflow, newer_workflow ])
      expect(job.workflows.last).to eq(newer_workflow)
    end
  end

  describe "Workflow#first_step" do
    it "chooses the lowest-id step when duplicate first-step positions exist" do
      job = Factories.job_record(state: "running")
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      first = Step.create!(workflow: workflow, kind: "prepare", position: 0)
      duplicate = Step.create!(workflow: workflow, kind: "implement", position: 0)

      expect(workflow.first_step).to eq(first)
      expect(workflow.steps.to_a).to eq([ first, duplicate ])
    end
  end
end
