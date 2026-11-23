require "rails_helper"

RSpec.describe WorkflowArtifactSanitizer do
  describe ".without_branch_divergence" do
    it "removes every branch divergence key and keeps the rest" do
      artifacts = {
        "branch_divergence" => { "a" => 1 },
        "branch_divergence_recovery" => true,
        "branch_divergence_recovery_error" => "boom",
        "branch_divergence_recovery_pending" => true,
        "typed_artifacts" => [ 1 ]
      }

      expect(described_class.without_branch_divergence(artifacts)).to eq("typed_artifacts" => [ 1 ])
    end

    it "treats nil as an empty hash and does not mutate the input" do
      expect(described_class.without_branch_divergence(nil)).to eq({})

      input = { "branch_divergence" => 1 }
      described_class.without_branch_divergence(input)
      expect(input).to eq("branch_divergence" => 1)
    end
  end
end
