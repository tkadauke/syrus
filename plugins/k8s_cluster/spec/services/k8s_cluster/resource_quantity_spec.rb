require "rails_helper"

RSpec.describe K8sCluster::ResourceQuantity do
  describe ".cpu_millicores" do
    it "parses a millicore string" do
      expect(described_class.cpu_millicores("250m")).to eq(250)
    end

    it "parses a nanocore string" do
      expect(described_class.cpu_millicores("250000000n")).to eq(250)
    end

    it "parses a whole-core string" do
      expect(described_class.cpu_millicores("2")).to eq(2000)
    end

    it "parses a fractional-core string" do
      expect(described_class.cpu_millicores("1.5")).to eq(1500)
    end

    it "returns 0 for a blank value" do
      expect(described_class.cpu_millicores(nil)).to eq(0)
      expect(described_class.cpu_millicores("")).to eq(0)
    end
  end

  describe ".memory_bytes" do
    it "parses a binary Ki suffix" do
      expect(described_class.memory_bytes("128Ki")).to eq(128 * 1024)
    end

    it "parses a binary Mi suffix" do
      expect(described_class.memory_bytes("512Mi")).to eq(512 * 1024 * 1024)
    end

    it "parses a binary Gi suffix" do
      expect(described_class.memory_bytes("2Gi")).to eq(2 * 1024 * 1024 * 1024)
    end

    it "parses a decimal K suffix" do
      expect(described_class.memory_bytes("500K")).to eq(500_000)
    end

    it "does not truncate a fractional suffixed value" do
      expect(described_class.memory_bytes("1.5Gi")).to eq((1.5 * 1024 * 1024 * 1024).round)
    end

    it "parses a plain byte count with no suffix" do
      expect(described_class.memory_bytes("128974848")).to eq(128_974_848)
    end

    it "returns 0 for a blank value" do
      expect(described_class.memory_bytes(nil)).to eq(0)
    end
  end
end
