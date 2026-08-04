require "rails_helper"

RSpec.describe WorkflowStepResourceProfile do
  let(:repository) { Factories.repository }

  def profile(sample_count:)
    described_class.new(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: "implement",
      grader_name: "",
      job_kind: "issue",
      sample_count: sample_count,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      profile_version: described_class::PROFILE_VERSION
    )
  end

  it "maps sample counts to profile confidence thresholds" do
    expect(profile(sample_count: 9).confidence_level).to eq("defaults_only")
    expect(profile(sample_count: 10).confidence_level).to eq("soft")
    expect(profile(sample_count: 29)).not_to be_permits_normal_admission
    expect(profile(sample_count: 30)).to be_permits_normal_admission
    expect(profile(sample_count: 99)).not_to be_permits_tight_confidence
    expect(profile(sample_count: 100)).to be_permits_tight_confidence
  end
end
