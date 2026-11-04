require "rails_helper"

RSpec.describe Diagnostics::SignalTrigger do
  around do |example|
    Dir.mktmpdir("diagnostics") { |dir| @diagnostics_dir = dir; example.run }
  end

  before { allow(described_class).to receive(:directory).and_return(@diagnostics_dir) }

  before { Diagnostics::HeapDiagnostics.register! }

  def write_request(payload) = File.write(described_class.request_path, JSON.generate(payload))

  describe "dispatch" do
    it "routes to the diagnostic the request file names" do
      write_request({ "kind" => "gc_stat" })

      path = described_class.run

      payload = JSON.parse(File.read(path))
      expect(payload).to include("kind" => "gc_stat", "pid" => Process.pid)
      expect(payload["gc_stat"]).to include("heap_live_slots")
    end

    it "names the output after the kind, pid and time so captures never collide" do
      write_request({ "kind" => "gc_stat" })

      path = described_class.run(now: Time.utc(2026, 11, 4, 9, 30, 0))

      expect(File.basename(path)).to eq("gc_stat-#{Process.pid}-20261104T093000.json")
    end

    # A signal is a blunt instrument: the request file may be absent, being
    # rewritten, or name something that no longer exists. None of those should
    # raise out of the trap path or leave the trigger wedged.
    it "reports an unknown kind without raising" do
      write_request({ "kind" => "nope" })

      expect(described_class.run).to be_nil
    end

    it "does nothing when the request file is missing or malformed" do
      expect(described_class.run).to be_nil

      File.write(described_class.request_path, "{not json")
      expect(described_class.run).to be_nil
    end

    it "lets a registered diagnostic return a path it wrote itself" do
      described_class.register("writes_own_file") do |request|
        request.path_for("txt").tap { |path| File.write(path, "hello") }
      end
      write_request({ "kind" => "writes_own_file" })

      path = described_class.run

      expect(File.read(path)).to eq("hello")
    end

    it "survives a diagnostic that raises" do
      described_class.register("explodes") { raise "boom" }
      write_request({ "kind" => "explodes" })

      expect { described_class.run }.not_to raise_error
      expect(described_class.run).to be_nil
    end
  end

  describe "triggering from a trap context" do
    # Two signals in quick succession must not stack two whole-heap walks on a
    # process that is already short of memory.
    it "runs at most one diagnostic at a time" do
      allow(described_class).to receive(:run) { sleep 0.2 }

      expect(described_class.request).to be(true)
      expect(described_class.request).to be(false)
    end

    it "never raises, and releases the guard when spawning fails" do
      allow(Thread).to receive(:new).and_raise(StandardError, "no threads")

      expect { described_class.request }.not_to raise_error
      allow(Thread).to receive(:new).and_call_original
      allow(described_class).to receive(:run)
      expect(described_class.request).to be(true)
    end
  end
end
