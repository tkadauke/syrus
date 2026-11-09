require "rails_helper"

RSpec.describe Permissions::Catalog, ".find!" do
  let(:descriptor) { described_class.descriptors.first }

  it "resolves a descriptor by capability and operation" do
    expect(described_class.find!(capability: descriptor.capability, operation: descriptor.operation))
      .to eq(descriptor)
  end

  it "resolves against a supplied snapshot without rebuilding the catalog" do
    snapshot = [ descriptor ]
    expect(described_class).not_to receive(:descriptors)

    expect(described_class.find!(capability: descriptor.capability, operation: descriptor.operation, from: snapshot))
      .to equal(descriptor)
  end

  it "does not see descriptors outside a supplied snapshot" do
    expect {
      described_class.find!(capability: descriptor.capability, operation: descriptor.operation, from: [])
    }.to raise_error(described_class::UnknownCapability)
  end
end
