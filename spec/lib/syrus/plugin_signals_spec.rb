require "rails_helper"

RSpec.describe Syrus::PluginSignals do
  let(:user) { Factories.user }

  # SpawnedProcess has no factory: these three columns are all this spec needs
  # and all the model requires.
  def spawned_process(hostname)
    SpawnedProcess.create!(hostname: hostname, kind: SpawnedProcess::KINDS.first, command: "true", started_at: Time.current)
  end

  describe "#repositories_detecting" do
    it "names the repositories whose last observation matched the plugin" do
      matching = Factories.repository(user: user, owner: "acme", name: "api")
      matching.update!(plugin_signals: %w[python javascript])
      Factories.repository(user: user, owner: "acme", name: "site").update!(plugin_signals: %w[javascript])

      expect(described_class.new.repositories_detecting("python")).to eq([ "acme/api" ])
    end

    it "ignores repositories that have never been observed" do
      Factories.repository(user: user, owner: "acme", name: "unseen")

      expect(described_class.new.repositories_detecting("python")).to be_empty
    end

    it "ignores archived repositories, whose layout is no longer a reason to enable anything" do
      repository = Factories.repository(user: user, owner: "acme", name: "old")
      repository.update!(plugin_signals: %w[python], archived_at: Time.current)

      expect(described_class.new.repositories_detecting("python")).to be_empty
    end
  end

  describe "#database_adapters" do
    it "reports every configured adapter, not just the one serving this request" do
      expect(described_class.new.database_adapters).to all(be_a(String))
      expect(described_class.new.database_adapters).to include(ActiveRecord::Base.connection_db_config.adapter)
    end
  end

  describe "#worker_hostnames" do
    it "counts distinct recent hosts" do
      spawned_process("worker-a")
      spawned_process("worker-a")
      spawned_process("worker-b")

      expect(described_class.new.worker_hostnames).to contain_exactly("worker-a", "worker-b")
    end

    it "ignores hosts that have not been seen inside the window" do
      spawned_process("retired").update_column(:created_at, 90.days.ago)

      expect(described_class.new.worker_hostnames).to be_empty
    end
  end

  it "answers with a safe empty value rather than raising when a signal cannot be read" do
    allow(Repository).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "no such column")

    expect(described_class.new.repositories_detecting("python")).to eq([])
  end
end
