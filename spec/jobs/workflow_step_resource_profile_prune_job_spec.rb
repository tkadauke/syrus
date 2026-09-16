require "rails_helper"

RSpec.describe WorkflowStepResourceProfilePruneJob do
  let(:repository) { Factories.repository }

  def profile(last_observed_at:, sha: SecureRandom.hex(4))
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: "implement_#{sha}",
      grader_name: "",
      job_kind: "issue",
      sample_count: 40,
      attributed_sample_count: 0,
      process_attributed_sample_count: 0,
      host_pressure_sample_count: 40,
      attribution_quality: "host_correlated",
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: last_observed_at,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  it "deletes stale profiles older than the retention window" do
    old = profile(last_observed_at: (WorkflowStepResourceProfile.retention_window + 1.day).ago)
    fresh = profile(last_observed_at: 1.day.ago)

    expect { described_class.perform_now }.to change { WorkflowStepResourceProfile.count }.by(-1)
    expect(WorkflowStepResourceProfile.exists?(old.id)).to be false
    expect(WorkflowStepResourceProfile.exists?(fresh.id)).to be true
  end

  it "logs the number of deleted rows" do
    profile(last_observed_at: 200.days.ago)
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(a_string_matching(/deleted 1 stale workflow step resource profiles/))
  end

  it "is a no-op when nothing is stale" do
    profile(last_observed_at: 1.day.ago)

    expect { described_class.perform_now }.not_to change { WorkflowStepResourceProfile.count }
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(workflow_step_resource_profile_retention_days: 0)
    old = profile(last_observed_at: 10.years.ago)

    expect { described_class.perform_now }.not_to change { WorkflowStepResourceProfile.count }
    expect(WorkflowStepResourceProfile.exists?(old.id)).to be true
  end
end
