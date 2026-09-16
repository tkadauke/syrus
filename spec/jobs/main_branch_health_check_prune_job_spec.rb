require "rails_helper"

RSpec.describe MainBranchHealthCheckPruneJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def check(checked_at:, sha: SecureRandom.hex(4))
    MainBranchHealthCheck.create!(
      repository: repository, sha: sha, checked_at: checked_at,
      ci_health: "unknown", grader_health: "unknown", source: "ci_poll"
    )
  end

  it "deletes checks older than the retention window" do
    old = check(checked_at: (MainBranchHealthCheck.retention_window + 1.day).ago)
    fresh = check(checked_at: 1.hour.ago)

    expect { described_class.perform_now }.to change { MainBranchHealthCheck.count }.by(-1)
    expect(MainBranchHealthCheck.exists?(old.id)).to be false
    expect(MainBranchHealthCheck.exists?(fresh.id)).to be true
  end

  it "logs the number of deleted rows" do
    check(checked_at: 10.days.ago)
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(a_string_matching(/deleted 1 main branch health checks/))
  end

  it "is a no-op when nothing is prunable" do
    check(checked_at: 1.hour.ago)

    expect { described_class.perform_now }.not_to change { MainBranchHealthCheck.count }
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(main_branch_health_check_retention_days: 0)
    old = check(checked_at: 10.years.ago)

    expect { described_class.perform_now }.not_to change { MainBranchHealthCheck.count }
    expect(MainBranchHealthCheck.exists?(old.id)).to be true
  end
end
