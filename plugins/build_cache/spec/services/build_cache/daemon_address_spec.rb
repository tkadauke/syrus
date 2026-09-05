require "rails_helper"

RSpec.describe BuildCache::DaemonAddress do
  it "derives a stable port from the workflow id" do
    workflow = instance_double(Workflow, id: 42)

    expect(described_class.port_for(workflow)).to eq(20042)
  end

  it "derives different ports for different workflow ids" do
    a = instance_double(Workflow, id: 1)
    b = instance_double(Workflow, id: 2)

    expect(described_class.port_for(a)).not_to eq(described_class.port_for(b))
  end

  it "keeps the derived port within a valid, non-privileged TCP port range" do
    [ 1, 39_999, 40_000, 123_456_789 ].each do |id|
      port = described_class.port_for(instance_double(Workflow, id: id))
      expect(port).to be_between(described_class::PORT_BASE, described_class::PORT_BASE + described_class::PORT_SPAN - 1)
    end
  end
end
