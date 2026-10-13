require "rails_helper"

RSpec.describe GraderResourceRequest do
  describe ".parse" do
    it "returns nil when nothing is declared" do
      expect(described_class.parse(nil)).to be_nil
    end

    it "returns nil for a declaration that only restates the defaults" do
      expect(described_class.parse({ "cpu" => 1, "cpu_min" => 1 })).to be_nil
    end

    it "parses a bounded core count" do
      request = described_class.parse({ "cpu" => 4 })

      expect(request.cpu).to eq(4)
      expect(request).not_to be_unbounded_cpu
    end

    it "parses an unbounded request" do
      request = described_class.parse({ "cpu" => "all" })

      expect(request).to be_unbounded_cpu
      expect(request.cpu_ceiling(10)).to eq(10)
    end

    it "caps a bounded request at what the host could offer" do
      expect(described_class.parse({ "cpu" => 64 }).cpu_ceiling(8)).to eq(8)
    end

    it "assumes a grader that declares no cpu is serial" do
      request = described_class.parse({ "memory" => "2GB" })

      expect(request.cpu).to eq(described_class::DEFAULT_CPU)
      expect(request.cpu).to eq(1)
    end

    it "parses memory sizes with binary units" do
      expect(described_class.parse({ "memory" => "6GB" }).memory_bytes).to eq(6 * 1024**3)
      expect(described_class.parse({ "memory" => "512mb" }).memory_bytes).to eq(512 * 1024**2)
      expect(described_class.parse({ "memory" => "1.5g" }).memory_bytes).to eq((1.5 * 1024**3).floor)
    end

    it "treats a bare number as bytes" do
      expect(described_class.parse({ "memory" => 1024 }).memory_bytes).to eq(1024)
    end

    it "accepts symbol keys" do
      expect(described_class.parse({ cpu: 2 }).cpu).to eq(2)
    end

    it "rejects unknown keys" do
      expect { described_class.parse({ "cpus" => 2 }) }
        .to raise_error(ArgumentError, /unknown keys cpus/)
    end

    it "rejects a non-mapping" do
      expect { described_class.parse("4") }.to raise_error(ArgumentError, /must be a mapping/)
    end

    it "rejects a non-positive core count" do
      expect { described_class.parse({ "cpu" => 0 }) }.to raise_error(ArgumentError, /positive integer/)
      expect { described_class.parse({ "cpu" => -1 }) }.to raise_error(ArgumentError, /positive integer/)
    end

    it "rejects a core count above the sanity ceiling" do
      expect { described_class.parse({ "cpu" => described_class::MAX_CPU + 1 }) }
        .to raise_error(ArgumentError, /at most/)
    end

    it "rejects an unbounded cpu_min" do
      expect { described_class.parse({ "cpu_min" => "all" }) }
        .to raise_error(ArgumentError, /cpu_min/)
    end

    it "rejects a malformed memory size" do
      expect { described_class.parse({ "memory" => "lots" }) }
        .to raise_error(ArgumentError, /byte count or a size/)
    end

    it "rejects an unknown memory unit" do
      expect { described_class.parse({ "memory" => "4pb" }) }
        .to raise_error(ArgumentError, /unknown unit/)
    end

    it "rejects a non-positive memory size" do
      expect { described_class.parse({ "memory" => 0 }) }.to raise_error(ArgumentError, /must be positive/)
    end
  end

  describe ".from_details" do
    it "round-trips through the Step#details representation" do
      request = described_class.new(cpu: described_class::ALL, cpu_min: 2, memory_bytes: 1024)

      expect(described_class.from_details(request.to_h)).to eq(request)
    end

    it "returns nil for a blank snapshot" do
      expect(described_class.from_details(nil)).to be_nil
      expect(described_class.from_details({})).to be_nil
    end

    it "falls back to the serial default for an unreadable cpu value" do
      expect(described_class.from_details({ "cpu" => "banana" }).cpu).to eq(1)
    end
  end
end
