require "rails_helper"

RSpec.describe Workflow::TriggerKind do
  describe ".retry_label_for" do
    it "returns 'Retry landing step' for auto_merge" do
      expect(described_class.retry_label_for("auto_merge")).to eq("Retry landing step")
    end

    it "returns 'Retry rebase step' for rebase and stack_rebase" do
      expect(described_class.retry_label_for("rebase")).to eq("Retry rebase step")
      expect(described_class.retry_label_for("stack_rebase")).to eq("Retry rebase step")
    end

    it "returns 'Retry failed step' for standard implementation kinds" do
      %w[initial retry pr_comment chat_feedback ci_failure].each do |kind|
        expect(described_class.retry_label_for(kind)).to eq("Retry failed step")
      end
    end

    it "returns 'Rebuild merge train' for merge_train when the failed step is merge_train_land" do
      expect(described_class.retry_label_for("merge_train", step_kind: "merge_train_land")).to eq("Rebuild merge train")
    end

    it "returns 'Retry merge train step' for merge_train when the failed step is not merge_train_land" do
      expect(described_class.retry_label_for("merge_train", step_kind: "merge_train_build")).to eq("Retry merge train step")
      expect(described_class.retry_label_for("merge_train")).to eq("Retry merge train step")
    end

    it "falls back to 'Retry failed step' for unknown trigger kinds" do
      expect(described_class.retry_label_for("unknown_kind")).to eq("Retry failed step")
    end
  end

  describe ".feedback_kind_for" do
    it "returns :chat_feedback for chat_feedback trigger kind" do
      expect(described_class.feedback_kind_for("chat_feedback")).to eq(:chat_feedback)
    end

    it "returns :pr_comment for pr_comment trigger kind" do
      expect(described_class.feedback_kind_for("pr_comment")).to eq(:pr_comment)
    end

    it "returns nil for non-feedback trigger kinds" do
      %w[initial retry auto_merge rebase stack_rebase ci_failure merge_train].each do |kind|
        expect(described_class.feedback_kind_for(kind)).to be_nil
      end
    end

    it "returns nil for unknown trigger kinds" do
      expect(described_class.feedback_kind_for("unknown")).to be_nil
    end
  end
end
