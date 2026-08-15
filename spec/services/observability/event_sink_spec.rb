require "rails_helper"

RSpec.describe Observability::EventSink do
  include ActiveJob::TestHelper

  around do |example|
    Dir.mktmpdir("syrus-observability-spool") do |dir|
      previous = ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"]
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = dir
      described_class.clear!
      example.run
      described_class.clear!
    ensure
      ENV["SYRUS_OBSERVABILITY_SPOOL_ROOT"] = previous
    end
  end

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Factories.repository(user: Factories.user, owner: "tkadauke", name: "syrus")
    clear_enqueued_jobs
    allow(SyrusVersion).to receive(:hostname).and_return("host-a")
  end

  after { clear_enqueued_jobs }

  it "buffers performance events and persists them on flush" do
    described_class.append(
      kind: :performance,
      event: {
        "event" => PerformanceLogging::SLOW_PHASE_EVENT,
        "occurred_at" => Time.zone.parse("2026-08-14T03:00:00Z").iso8601(6),
        "app_revision" => "sha-a",
        "phase" => "dashboard_payload",
        "duration_ms" => 1250.0
      }
    )

    expect(PerformanceLogEvent.count).to eq(0)
    expect(described_class.recent(kind: :performance, limit: 10).first).to include("phase" => "dashboard_payload")

    described_class.flush!(kinds: [ :performance ])

    expect(PerformanceLogEvent.count).to eq(1)
    expect(PerformanceLogEvent.first).to have_attributes(
      event_name: PerformanceLogging::SLOW_PHASE_EVENT,
      app_revision: "sha-a",
      phase: "dashboard_payload",
      duration_ms: 1250.0
    )
  end

  it "spools operational events and persists them only when flushed" do
    described_class.append(
      kind: :operational,
      event: {
        "event" => "operational.log",
        "occurred_at" => Time.current.iso8601(6),
        "level" => "error",
        "role" => "worker",
        "hostname" => "host-a",
        "source" => "spec",
        "message" => "sidecar failed",
        "context" => { "run_id" => "81234" }
      },
      durable: true
    )

    expect(OperationalLogEvent.count).to eq(0)
    expect(Dir.glob(File.join(ENV.fetch("SYRUS_OBSERVABILITY_SPOOL_ROOT"), "**", "*.jsonl"))).not_to be_empty

    described_class.clear!(kind: :operational)
    expect(OperationalLogEvent.count).to eq(0)
  end

  it "deduplicates memory and spool copies when flushing durable operational events" do
    event = {
      "occurred_at" => Time.current.iso8601(6),
      "level" => "warn",
      "role" => "worker",
      "hostname" => "host-a",
      "source" => "spec",
      "message" => "queued retry",
      "context" => {}
    }

    described_class.append(kind: :operational, event: event, durable: true)

    expect {
      described_class.flush!(kinds: [ :operational ])
    }.to change(OperationalLogEvent, :count).by(1)
    expect(enqueued_jobs.map { |job| job[:job] }).to include(IndexOperationalLogEventJob)
  end

  it "logs instead of silently dropping an event when append fails" do
    allow(described_class).to receive(:append_memory).and_raise(RuntimeError, "buffer mutex poisoned")
    allow(Rails.logger).to receive(:error)

    result = described_class.append(kind: :operational, event: { "message" => "hello" })

    expect(result).to be_nil
    expect(Rails.logger).to have_received(:error).with(a_string_matching(/append failed for operational.*RuntimeError.*buffer mutex poisoned/))
  end

  it "logs and restores events to the buffer instead of silently dropping them when flush fails" do
    described_class.append(kind: :operational, event: {
      "occurred_at" => Time.current.iso8601(6),
      "level" => "error",
      "role" => "worker",
      "hostname" => "host-a",
      "source" => "spec",
      "message" => "will fail to persist",
      "context" => {}
    }, durable: true)
    allow(OperationalLogEvent).to receive(:create!).and_raise(RuntimeError, "db unavailable")
    allow(Rails.logger).to receive(:error)

    expect {
      described_class.flush!(kinds: [ :operational ])
    }.not_to change(OperationalLogEvent, :count)

    expect(Rails.logger).to have_received(:error).with(a_string_matching(/flush failed for operational, 1 event\(s\) restored to buffer/))
    expect(described_class.recent(kind: :operational, limit: 10).size).to eq(1)
  end
end
