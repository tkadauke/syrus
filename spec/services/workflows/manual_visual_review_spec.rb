require "rails_helper"

RSpec.describe Workflows::ManualVisualReview do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented") }

  describe ".trigger_kind" do
    it "is manual_visual_review" do
      expect(described_class.trigger_kind).to eq("manual_visual_review")
    end
  end

  describe ".steps_for" do
    it "runs prepare then a standalone visual_review step" do
      expect(described_class.steps_for(job)).to eq(%w[prepare visual_review])
    end

    it "omits prepare when the job has a skip_prepare reason" do
      allow(job).to receive(:skip_prepare?).and_return(true)
      expect(described_class.steps_for(job)).to eq(%w[visual_review])
    end
  end

  describe ".instantiate" do
    it "materializes a single visual_review step outside any loop" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.trigger_kind).to eq("manual_visual_review")
      review_step = workflow.steps.find_by!(kind: "visual_review")
      expect(review_step.loop_id).to be_nil
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare visual_review])
    end
  end
end
