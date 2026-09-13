require "rails_helper"

RSpec.describe StorageConnectivity do
  FakeService = Struct.new(:name, :error) do
    def exist?(_key)
      raise error if error

      false
    end
  end

  it "reports available when the configured service can answer a probe" do
    result = described_class.check(service: FakeService.new("test", nil))

    expect(result).to have_attributes(
      available: true,
      service: "test",
      error_class: nil,
      message: nil
    )
  end

  it "reports transient connection failures as unavailable" do
    result = described_class.check(service: FakeService.new("minio", Errno::ECONNREFUSED.new("minio:9000")))

    expect(result).to have_attributes(
      available: false,
      service: "minio",
      error_class: "Errno::ECONNREFUSED"
    )
  end

  it "does not swallow non-transient storage errors" do
    expect {
      described_class.check(service: FakeService.new("test", ActiveStorage::FileNotFoundError.new("missing")))
    }.to raise_error(ActiveStorage::FileNotFoundError)
  end
end
