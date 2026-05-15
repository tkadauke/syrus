require "rails_helper"

RSpec.describe JobsHelper, type: :helper do
  describe "#workflow_label" do
    it "labels retry workflows as Retry" do
      expect(helper.workflow_label("retry")).to eq("Retry")
    end

    it "labels legacy replay trigger values as Retry" do
      expect(helper.workflow_label("replay")).to eq("Retry")
    end
  end

  describe "#current_step_caption" do
    let(:job) { job_with_workflow }

    def job_with_workflow
      j = Factories.job
      j
    end

    def add_workflow(job, state:, trigger_kind: "initial")
      wf = Workflow.create!(job: job, trigger_kind: trigger_kind, state: state)
      Step.create!(workflow: wf, kind: "implement", position: 0)
      wf
    end

    it "returns nil when the job has no workflows" do
      j = Factories.job
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is queued" do
      j = Factories.job
      add_workflow(j, state: "queued")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is terminal (succeeded)" do
      j = Factories.job
      add_workflow(j, state: "succeeded")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is terminal (failed)" do
      j = Factories.job
      add_workflow(j, state: "failed")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns a caption when the workflow is running" do
      j = Factories.job
      add_workflow(j, state: "running", trigger_kind: "initial")
      caption = helper.current_step_caption(j)
      expect(caption).to be_present
      expect(caption).to include("currently:")
    end

    it "includes the step kind label for a running workflow" do
      j = Factories.job
      wf = Workflow.create!(job: j, trigger_kind: "initial", state: "running")
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "running")
      caption = helper.current_step_caption(j)
      expect(caption).to include("Implement")
    end
  end
end
