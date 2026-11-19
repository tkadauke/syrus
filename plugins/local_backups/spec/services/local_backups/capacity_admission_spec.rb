require "rails_helper"

RSpec.describe LocalBackups::CapacityAdmission do
  let(:root) { instance_double(LocalBackups::StorageRoot, path: Pathname.new(Dir.tmpdir)) }

  it "fails before construction when sealed data, dump, overhead, and reserve do not fit" do
    admission = described_class.new(
      root:, available_bytes: 1_499, capacity_bytes: 10_000,
      absolute_reserve: 100, percent_reserve: 10
    )

    expect { admission.admit!(database_bytes: 100, blob_bytes: 100) }
      .to raise_error(described_class::InsufficientSpace) do |error|
        expect(error.required_bytes).to eq(1_500)
        expect(error.available_bytes).to eq(1_499)
      end
  end

  it "estimates from the largest of the three most recent completed backups" do
    [
      [9_000, 4.days.ago],
      [100, 3.days.ago],
      [300, 2.days.ago],
      [200, 1.day.ago]
    ].each do |stored_bytes, completed_at|
      LocalBackups::Backup.create!(
        uuid: SecureRandom.uuid, state: "completed", artifact_relative_path: "sealed-#{stored_bytes}",
        manifest_version: "1.0", stored_bytes:, completed_at:
      )
    end
    admission = described_class.new(
      root:, available_bytes: 10_000, capacity_bytes: 10_000,
      absolute_reserve: 100, percent_reserve: 10
    )

    expect(admission.admit!(database_bytes: 100, blob_bytes: 100)).to eq(1_700)
  end
end
