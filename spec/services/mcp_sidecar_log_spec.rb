require "rails_helper"

RSpec.describe McpSidecarLog do
  around do |example|
    original = ENV["SYRUS_DATA_ROOT"]
    example.run
  ensure
    ENV["SYRUS_DATA_ROOT"] = original
  end

  describe ".path_for" do
    it "returns a path under the mcp-sidecar-logs root for the given run id" do
      path = described_class.path_for(42)

      expect(path.to_s).to end_with("/mcp-sidecar-logs/run-42.stderr.log")
    end
  end

  describe ".root" do
    it "uses SYRUS_DATA_ROOT env var when set" do
      ENV["SYRUS_DATA_ROOT"] = "/custom/root"

      expect(described_class.root.to_s).to eq("/custom/root/mcp-sidecar-logs")
    end
  end

  describe ".tail" do
    it "returns an empty string when no log file exists for the run" do
      result = described_class.tail(999_999_999)

      expect(result).to eq("")
    end

    it "returns the full file content when it fits within the byte limit" do
      Dir.mktmpdir do |dir|
        ENV["SYRUS_DATA_ROOT"] = dir
        log_dir = Pathname.new(dir).join("mcp-sidecar-logs")
        log_dir.mkpath
        log_dir.join("run-1.stderr.log").write("sidecar started\nsome output\n")

        result = described_class.tail(1)

        expect(result).to eq("sidecar started\nsome output\n")
      end
    end

    it "returns only the last MAX_CAPTURE_BYTES when the file is larger" do
      Dir.mktmpdir do |dir|
        ENV["SYRUS_DATA_ROOT"] = dir
        log_dir = Pathname.new(dir).join("mcp-sidecar-logs")
        log_dir.mkpath

        max = McpSidecarLog::MAX_CAPTURE_BYTES
        content = "x" * (max + 100)
        log_dir.join("run-2.stderr.log").binwrite(content)

        result = described_class.tail(2)

        expect(result.bytesize).to eq(max)
        expect(result).to eq(content[-max..])
      end
    end

    it "returns an error message string when reading fails" do
      Dir.mktmpdir do |dir|
        ENV["SYRUS_DATA_ROOT"] = dir
        log_dir = Pathname.new(dir).join("mcp-sidecar-logs")
        log_dir.mkpath
        log_dir.join("run-3.stderr.log").write("data")

        allow(File).to receive(:binread).and_raise(Errno::EACCES, "permission denied")

        result = described_class.tail(3)

        expect(result).to match(/failed to read MCP sidecar stderr log/)
        expect(result).to match(/Errno::EACCES/)
      end
    end
  end
end
