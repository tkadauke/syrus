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
      attributed_sample_count: 0,
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

  it "prefers attributed command predictions when they are sufficiently sampled" do
    profile = profile(sample_count: 40)
    profile.assign_attributes(
      attributed_sample_count: 10,
      p90_duration_seconds: 900,
      p90_cpu_pressure: 80.0,
      p90_attributed_duration_seconds: 120,
      p90_attributed_cpu_pressure: 20.0,
      p90_attributed_io_pressure: 10.0,
      p90_attributed_memory_used_percent: 45.0
    )

    expect(profile.conservative_prediction).to include(
      duration_seconds: 120,
      cpu_pressure: 20.0,
      prediction_source: "command_attributed",
      attribution_confidence_level: "soft",
      fallback_reason: nil
    )
  end

  it "falls back to host-correlated profile data when command attribution is not confident" do
    profile = profile(sample_count: 40)
    profile.assign_attributes(
      attributed_sample_count: 9,
      p90_duration_seconds: 900,
      p90_cpu_pressure: 80.0,
      p90_io_pressure: 25.0,
      p90_memory_used_percent: 55.0
    )

    expect(profile.conservative_prediction).to include(
      duration_seconds: 900,
      cpu_pressure: 80.0,
      prediction_source: "host_correlated",
      fallback_reason: "command_attributed_profile_unavailable"
    )
  end

  it "treats legacy sample-only profiles as host-correlated predictions" do
    profile = profile(sample_count: 40)
    profile.assign_attributes(
      host_pressure_sample_count: 0,
      p90_duration_seconds: 600,
      p90_cpu_pressure: 35.0
    )

    expect(profile.confidence_level).to eq("normal")
    expect(profile.prediction_basis).to eq("host_correlated")
    expect(profile.conservative_prediction).to include(
      duration_seconds: 600,
      cpu_pressure: 35.0,
      prediction_source: "host_correlated"
    )
  end
end
