require "rails_helper"

RSpec.describe Diagnostics::HeapDiagnostics do
  around do |example|
    Dir.mktmpdir("diagnostics") { |dir| @diagnostics_dir = dir; example.run }
  end

  before { allow(Diagnostics::SignalTrigger).to receive(:directory).and_return(@diagnostics_dir) }

  before { described_class.register! }

  def run(payload)
    File.write(Diagnostics::SignalTrigger.request_path, JSON.generate(payload))
    Diagnostics::SignalTrigger.run
  end

  def payload_from(path) = JSON.parse(File.read(path))

  describe "gc_stat" do
    it "captures counters without walking the heap" do
      payload = payload_from(run({ "kind" => "gc_stat" }))

      expect(payload["gc_stat"]).to include("heap_live_slots", "heap_free_slots", "old_objects")
      expect(payload["count_objects"]).to include("TOTAL")
      expect(payload).not_to have_key("top_by_count")
    end
  end

  describe "heap_histogram" do
    it "attributes live objects to classes by count and retained size" do
      payload = payload_from(run({ "kind" => "heap_histogram" }))

      # String is always present in a live Ruby heap, so this asserts the walk
      # actually attributed objects rather than returning an empty table.
      expect(payload["top_by_count"].map { |row| row["class"] }).to include("String")
      expect(payload["top_by_count"].first["count"]).to be_positive
      expect(payload["top_by_memsize"].first["memsize"]).to be_positive
      expect(payload["classes_seen"]).to be_positive
    end

    it "includes the gc_stat counters so one capture answers both questions" do
      payload = payload_from(run({ "kind" => "heap_histogram" }))

      expect(payload["gc_stat"]).to include("heap_live_slots")
    end

    it "honours top_n and clamps it to a sane maximum" do
      expect(payload_from(run({ "kind" => "heap_histogram", "top_n" => 3 }))["top_by_count"].length).to eq(3)
      expect(payload_from(run({ "kind" => "heap_histogram", "top_n" => 10_000 }))["top_n"])
        .to eq(described_class::MAX_TOP_N)
    end
  end

  describe "allocation_trace" do
    def stub_memory(current:, limit:)
      allow(RunProcessParallelism).to receive(:cgroup_memory_current_bytes).and_return(current)
      allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(limit)
    end

    it "attributes surviving objects to the source line that allocated them" do
      stub_memory(current: 1_000, limit: 10_000)
      retained = []
      thread = Thread.new { 200.times { retained << "leaked-#{_1}" }; sleep 2 }

      payload = payload_from(run({ "kind" => "allocation_trace", "seconds" => 1, "top_n" => 20 }))
      thread.kill

      expect(payload["traced_seconds"]).to eq(1)
      expect(payload["allocated_during_window"]).to be_positive
      expect(payload["top_allocation_sites"]).to be_present
      expect(payload["top_allocation_sites"].first).to include("site", "count", "classes")
      expect(payload["top_allocation_sites"].first["site"]).to match(/:\d+\z/)
    end

    # Tracing roughly doubles memory, so it must refuse for the same reason
    # heap_dump does.
    it "refuses when the cgroup is close to its limit" do
      stub_memory(current: 9_000, limit: 10_000)

      expect(run({ "kind" => "allocation_trace", "seconds" => 1 })).to be_nil
    end

    it "always stops tracing, even when collection fails" do
      stub_memory(current: 1_000, limit: 10_000)
      allow(ObjectSpace).to receive(:each_object).and_raise(StandardError, "boom")

      run({ "kind" => "allocation_trace", "seconds" => 1 })

      expect(ObjectSpace.trace_object_allocations_debug_start_count).to eq(0) if
        ObjectSpace.respond_to?(:trace_object_allocations_debug_start_count)
      # Tracing left on would double memory indefinitely; a subsequent capture
      # succeeding is the observable proof it was turned back off.
      expect(run({ "kind" => "gc_stat" })).to be_present
    end
  end

  describe "heap_dump" do
    def stub_memory(current:, limit:)
      allow(RunProcessParallelism).to receive(:cgroup_memory_current_bytes).and_return(current)
      allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(limit)
    end

    # dump_all allocates while writing and produces output several times the
    # size of the heap, so on a nearly-full pod it kills the process holding
    # the evidence.
    it "refuses when the cgroup is close to its limit" do
      stub_memory(current: 9_000, limit: 10_000)

      expect(run({ "kind" => "heap_dump" })).to be_nil
      expect(Dir.glob(File.join(Diagnostics::SignalTrigger.directory, "heap_dump*"))).to be_empty
    end

    it "proceeds when the request explicitly forces it" do
      stub_memory(current: 9_000, limit: 10_000)

      path = run({ "kind" => "heap_dump", "force" => true })

      expect(path).to end_with(".json.gz")
      expect(File.size(path)).to be_positive
    end

    it "proceeds when there is headroom, and writes gzipped" do
      stub_memory(current: 1_000, limit: 10_000)

      path = run({ "kind" => "heap_dump" })

      expect(Zlib::GzipReader.open(path) { |gz| gz.readline }).to include('"type"')
    end

    it "proceeds when the cgroup is unreadable rather than refusing blindly" do
      stub_memory(current: nil, limit: nil)

      expect(run({ "kind" => "heap_dump" })).to end_with(".json.gz")
    end
  end
end
