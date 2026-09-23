require "rails_helper"

RSpec.describe BuildCache::DaemonAddress do
  it "derives a stable port from the scope's cache_key" do
    scope = PrepareScope.new(namespace: "workflow", id: 42, repository: nil)

    expect(described_class.port_for(scope)).to eq(described_class.port_for(scope))
  end

  it "derives different ports for different scope ids" do
    a = PrepareScope.new(namespace: "workflow", id: 1, repository: nil)
    b = PrepareScope.new(namespace: "workflow", id: 2, repository: nil)

    expect(described_class.port_for(a)).not_to eq(described_class.port_for(b))
  end

  it "derives different ports for a workflow scope and a chat scope with the same numeric id" do
    workflow_scope = PrepareScope.new(namespace: "workflow", id: 42, repository: nil)
    chat_scope = PrepareScope.new(namespace: "chat", id: 42, repository: nil)

    expect(described_class.port_for(workflow_scope)).not_to eq(described_class.port_for(chat_scope))
  end

  it "keeps the derived port within a valid, non-privileged TCP port range" do
    [ 1, 39_999, 40_000, 123_456_789 ].each do |id|
      port = described_class.port_for(PrepareScope.new(namespace: "workflow", id: id, repository: nil))
      expect(port).to be_between(described_class::PORT_BASE, described_class::PORT_BASE + described_class::PORT_SPAN - 1)
    end
  end
end
