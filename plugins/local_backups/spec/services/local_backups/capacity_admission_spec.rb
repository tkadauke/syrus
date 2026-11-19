require "rails_helper"

RSpec.describe LocalBackups::CapacityAdmission do
  it "fails before construction when sealed data, dump, overhead, and reserve do not fit" do
    root = instance_double(LocalBackups::StorageRoot, path: Pathname.new(Dir.tmpdir))
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
end
