require "rails_helper"

RSpec.describe WorkerQueueTopology do
  describe "#consumes?" do
    it "is true for a queue a single-host queue.yml worker consumes" do
      topology = described_class.new(config_file: Rails.root.join("config/queue.yml"))

      expect(topology.consumes?("polling")).to be true
      expect(topology.consumes?("runs")).to be true
    end

    it "is true for polling on a home-tier config" do
      topology = described_class.new(config_file: Rails.root.join("config/queue.home.yml"))

      expect(topology.consumes?("polling")).to be true
    end

    it "is false for polling on a compute-tier config that only runs runs/merges" do
      topology = described_class.new(config_file: Rails.root.join("config/queue.compute.yml"))

      expect(topology.consumes?("polling")).to be false
    end

    it "is true for runs on a compute-tier config" do
      topology = described_class.new(config_file: Rails.root.join("config/queue.compute.yml"))

      expect(topology.consumes?("runs")).to be true
    end

    it "is false for a queue a compute-tier config does not consume" do
      topology = described_class.new(config_file: Rails.root.join("config/queue.compute.yml"))

      expect(topology.consumes?("indexing")).to be false
    end

    it "falls back to Solid Queue's own wildcard default (consumes everything) when the config file is missing, instead of raising" do
      topology = described_class.new(config_file: Rails.root.join("config/does-not-exist.yml"))

      expect(topology.consumes?("polling")).to be true
    end

    it "swallows unexpected errors and reports no consumed queues rather than raising" do
      topology = described_class.new
      broken_configuration = instance_double(SolidQueue::Configuration)
      allow(topology).to receive(:configuration).and_return(broken_configuration)
      allow(broken_configuration).to receive(:configured_processes).and_raise(StandardError, "boom")

      expect(topology.consumes?("polling")).to be false
    end
  end

  describe ".consumes?" do
    it "delegates to a new instance" do
      expect(described_class.consumes?("runs", config_file: Rails.root.join("config/queue.yml"))).to be true
    end
  end

  describe ".queues_include?" do
    it "is true for an exact match" do
      expect(described_class.queues_include?(%w[runs merges], "runs")).to be true
    end

    it "is false when the queue is absent" do
      expect(described_class.queues_include?(%w[runs merges], "polling")).to be false
    end

    it "is true for the `*` wildcard regardless of the other configured queues" do
      expect(described_class.queues_include?(%w[*], "polling")).to be true
      expect(described_class.queues_include?(%w[runs *], "polling")).to be true
    end

    it "is true for a prefix wildcard that matches" do
      expect(described_class.queues_include?(%w[poll*], "polling")).to be true
    end

    it "is false for a prefix wildcard that does not match" do
      expect(described_class.queues_include?(%w[run*], "polling")).to be false
    end

    it "accepts a comma-joined queue string as stored on SolidQueue::Process#metadata" do
      expect(described_class.queues_include?("resume-abc,runs".split(","), "runs")).to be true
    end
  end
end
