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

  it "uses small batches for performance log inserts" do
    stream = Observability::EventStream.fetch(:performance)

    expect(stream.batch_size).to eq(25)
  end

  it "allows a larger in-memory window for performance diagnostics than generic operational events" do
    stub_const("Observability::EventSink::MEMORY_LIMIT", 2)
    stub_const("Observability::EventSink::PERFORMANCE_MEMORY_LIMIT", 4)

    5.times do |index|
      described_class.append(kind: :operational, event: {
        "event" => "operational.log",
        "occurred_at" => "2026-08-14T03:00:0#{index}Z",
        "message" => "operational #{index}"
      })
      described_class.append(kind: :performance, event: {
        "event" => PerformanceLogging::BROWSER_TRACE_EVENT,
        "occurred_at" => "2026-08-14T03:00:0#{index}Z",
        "name" => "dashboard.route",
        "trace_id" => "trace-#{index}"
      })
    end

    expect(described_class.recent(kind: :operational, limit: 10).size).to eq(2)
    expect(described_class.recent(kind: :performance, limit: 10).size).to eq(4)
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

  it "persists heterogeneous insert_all rows for optional event fields" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "codex")
    step = workflow.steps.create!(kind: "prepare", position: 1)
    described_class.clear!(kind: :workflow_activity)
    WorkflowActivityEvent.delete_all

    described_class.append(kind: :workflow_activity, durable: true, event: {
      "occurred_at" => Time.current.iso8601(6),
      "event_type" => "workflow_started",
      "source" => "spec",
      "severity" => "info",
      "job_id" => job.id,
      "workflow_id" => workflow.id,
      "trigger_kind" => "initial",
      "workflow_state" => "running",
      "message" => "workflow started",
      "metadata" => {}
    })
    described_class.append(kind: :workflow_activity, durable: true, event: {
      "occurred_at" => Time.current.iso8601(6),
      "event_type" => "run_started",
      "source" => "spec",
      "severity" => "info",
      "job_id" => job.id,
      "workflow_id" => workflow.id,
      "step_id" => step.id,
      "step_kind" => "prepare",
      "message" => "run started",
      "metadata" => {}
    })

    expect {
      described_class.flush!(kinds: [ :workflow_activity ])
    }.to change(WorkflowActivityEvent, :count).by(2)
  end
end
