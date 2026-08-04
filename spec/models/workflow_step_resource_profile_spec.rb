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
      host_pressure_sample_count: sample_count,
      process_attributed_sample_count: 0,
      attribution_quality: sample_count.positive? ? "host_correlated" : "defaults_only",
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

  it "uses process-attributed confidence before host fallback for prediction basis" do
    host_only = profile(sample_count: 30)
    process_backed = profile(sample_count: 30)
    process_backed.process_attributed_sample_count = 10
    process_backed.attribution_quality = "mixed"

    expect(host_only.prediction_basis).to eq("host_correlated")
    expect(process_backed.prediction_basis).to eq("process_attributed")
    expect(process_backed).to be_prefers_process_attribution
  end
end
