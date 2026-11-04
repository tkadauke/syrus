require "rails_helper"

RSpec.describe Diagnostics::ProcessDiagnostics do
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

  describe "thread_backtraces" do
    it "captures a backtrace per live thread and marks the main thread" do
      payload = payload_from(run({ "kind" => "thread_backtraces" }))

      expect(payload["thread_count"]).to be_positive
      main = payload["threads"].find { |thread| thread["main"] }
      expect(main).to be_present
      expect(main["backtrace"]).to be_an(Array).and be_present
      expect(main["alive"]).to be(true)
    end

    it "caps backtrace depth so one wedged process cannot produce an unbounded file" do
      payload = payload_from(run({ "kind" => "thread_backtraces", "depth" => 2 }))

      expect(payload["threads"].map { |thread| thread["backtrace"].length }.max).to be <= 2
    end

    it "keeps a thread that cannot be inspected from failing the whole capture" do
      broken = instance_double(Thread)
      allow(broken).to receive(:name).and_return("broken")
      allow(broken).to receive(:status).and_raise(StandardError, "gone")
      allow(Thread).to receive(:list).and_return([ Thread.main, broken ])

      payload = payload_from(run({ "kind" => "thread_backtraces" }))

      expect(payload["threads"].map { |thread| thread["error"] }.compact).to be_present
    end
  end

  describe "db_pool" do
    # Connection starvation is indistinguishable from slow queries from the
    # outside; `waiting` is the field that tells them apart.
    it "reports pool saturation including the waiting count" do
      payload = payload_from(run({ "kind" => "db_pool" }))

      expect(payload["pools"]).to be_present
      pool = payload["pools"].first
      expect(pool).to include("size", "busy", "waiting")
      expect(pool["waiting"]).to be >= 0
    end

    it "degrades to an error entry rather than failing the capture" do
      allow(ActiveRecord::Base.connection_handler).to receive(:connection_pool_list).and_raise(StandardError, "no handler")

      expect(payload_from(run({ "kind" => "db_pool" }))["pools"].first).to include("error")
    end
  end

  describe "fd_table" do
    it "classifies descriptors when /proc is available, and says so when it is not" do
      payload = payload_from(run({ "kind" => "fd_table" }))
      table = payload["file_descriptors"]

      if table.key?("available")
        expect(table["available"]).to be(false)
      else
        expect(table["total"]).to be_positive
        expect(table["by_kind"]).to be_present
      end
    end
  end

  describe "process_overview" do
    it "combines GC, threads, pools and descriptors so triage needs one signal" do
      payload = payload_from(run({ "kind" => "process_overview" }))

      expect(payload["gc_stat"]).to include("heap_live_slots")
      expect(payload["threads"]).to be_present
      expect(payload["pools"]).to be_present
      expect(payload["file_descriptors"]).to be_present
    end

    it "keeps backtraces shallow so the composite stays small" do
      payload = payload_from(run({ "kind" => "process_overview" }))

      expect(payload["threads"].map { |thread| Array(thread["backtrace"]).length }.max)
        .to be <= described_class::OVERVIEW_BACKTRACE_DEPTH
    end
  end
end
