require "rails_helper"

RSpec.describe TargetHealthRecord do
  let(:repository) { Factories.repository }
  let(:lookup) do
    {
      repository: repository,
      target_label: "//cli:grade/tests",
      commit_sha: "abc123",
      input_fingerprint: "input-fp",
      command_fingerprint: "command-fp",
      environment_fingerprint: "env-fp"
    }
  end

  it "requires the target lookup fields and a known status" do
    record = described_class.new

    expect(record).not_to be_valid
    expect(record.errors).to include(
      :repository,
      :target_label,
      :project_id,
      :commit_sha,
      :input_fingerprint,
      :command_fingerprint,
      :environment_fingerprint,
      :status,
      :checked_at
    )

    record.assign_attributes(valid_attributes(status: "maybe"))
    expect(record).not_to be_valid
    expect(record.errors[:status]).to include("is not included in the list")
  end

  it "enforces one current row for a target, commit, and fingerprint tuple" do
    described_class.create!(valid_attributes)

    duplicate = described_class.new(valid_attributes(status: "failed"))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:repository_id]).to include("has already been taken")
  end

  it "finds the latest matching target health outside a workflow" do
    old = described_class.create!(valid_attributes(status: "failed", checked_at: 2.hours.ago))
    latest = described_class.create!(
      valid_attributes(
        commit_sha: "def456",
        status: "passed",
        checked_at: 1.hour.ago
      )
    )

    expect(described_class.latest_for(**lookup)).to eq(old)
    expect(described_class.latest_for(**lookup.merge(commit_sha: "def456"))).to eq(latest)
    expect(described_class.passed_for?(**lookup.merge(commit_sha: "def456"))).to eq(true)
  end

  it "finds the latest reusable record by fingerprints without requiring the same commit sha" do
    described_class.create!(valid_attributes(status: "passed", commit_sha: "oldsha", checked_at: 2.hours.ago))
    failed = described_class.create!(valid_attributes(status: "failed", commit_sha: "newsha", checked_at: 1.hour.ago))

    expect(
      described_class.latest_for_reusable_inputs(
        repository: repository,
        target_label: "//cli:grade/tests",
        input_fingerprint: "input-fp",
        command_fingerprint: "command-fp",
        environment_fingerprint: "env-fp"
      )
    ).to eq(failed)
  end

  it "classifies statuses for target selection" do
    passed = described_class.new(valid_attributes(status: "passed"))
    stale = described_class.new(valid_attributes(status: "stale", target_label: "//cli:grade/lint"))
    failed = described_class.new(valid_attributes(status: "failed", target_label: "//cli:grade/types"))

    expect(passed).to be_healthy
    expect(stale).not_to be_healthy
    expect(stale).not_to be_unhealthy
    expect(failed).to be_unhealthy
  end

  private

  def valid_attributes(overrides = {})
    lookup.merge(
      project_id: "cli",
      status: "passed",
      checked_at: Time.current,
      artifacts: { "log_path" => "logs/target.log" },
      metadata: { "source" => "spec" }
    ).merge(overrides)
  end
end
