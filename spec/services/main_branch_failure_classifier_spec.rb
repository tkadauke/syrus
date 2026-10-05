require "rails_helper"

RSpec.describe MainBranchFailureClassifier do
  describe MainBranchFailureClassifier::LandingBaseSha do
    let(:job) { Factories.job }
    let(:workflow) { job.workflows.first }

    it "uses the current mergeability base for auto-merge workflows" do
      workflow.update!(trigger_kind: "auto_merge")
      job.update!(mergeability_base_sha: "current-base")

      expect(described_class.for(workflow).value).to eq("current-base")
    end

    it "uses the built integration base for merge-train workflows" do
      workflow.update!(trigger_kind: "merge_train")
      workflow.set_artifact!("merge_train_base_sha", "train-base")

      expect(described_class.for(workflow).value).to eq("train-base")
    end

    it "uses the predicted base for speculative landing validations" do
      workflow.update!(trigger_kind: "landing_validation")
      workflow.set_artifact!("predicted_base_sha", "predicted-base")

      expect(described_class.for(workflow).value).to eq("predicted-base")
    end

    it "falls back to the repository's last health-checked revision" do
      job.repository.update!(last_health_checked_sha: "healthy-base")

      expect(described_class.for(workflow).value).to eq("healthy-base")
    end
  end
end
