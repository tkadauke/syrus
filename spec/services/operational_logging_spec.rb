require "rails_helper"

RSpec.describe OperationalLogging do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Current.reset
    clear_enqueued_jobs
    allow(SyrusVersion).to receive(:current).and_return("sha-test")
    allow(SyrusVersion).to receive(:hostname).and_return("host-a")
  end

  after do
    Current.reset
    clear_enqueued_jobs
  end

  it "does not ingest or schedule indexing while disabled" do
    Feature.find_by!(slug: "operational_log_indexing").update!(enabled: false)
    Current.reset

    expect {
      described_class.ingest(level: "info", source: "spec", message: "hello")
    }.not_to change(OperationalLogEvent, :count)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(IndexOperationalLogEventJob)
  end

  it "does not ingest when no Syrus repository or registered fork is active" do
    repository.update!(archived_at: Time.current)
    Current.reset

    expect {
      described_class.ingest(level: "info", source: "spec", message: "hello")
    }.not_to change(OperationalLogEvent, :count)
  end

  it "redacts secrets, truncates large payloads, and enqueues default-queue indexing" do
    event = nil

    expect {
      event = described_class.ingest(
        level: "warn",
        role: "worker",
        source: "spec",
        message: "token=abc123 " + ("x" * 5_000),
        context: {
          request_id: "req-1",
          api_key: "api_key=secret-value",
          extra: "y" * 10_000
        }
      )
    }.to change(OperationalLogEvent, :count).by(1)

    expect(event.message).to start_with("token=[REDACTED]")
    expect(event.message.bytesize).to be <= described_class::MAX_MESSAGE_BYTES
    expect(event.context.to_json.bytesize).to be <= described_class::MAX_CONTEXT_BYTES
    expect(event.context.to_json).not_to include("secret-value")
    expect(enqueued_jobs.map { |job| job[:job] }).to include(IndexOperationalLogEventJob)
    expect(enqueued_jobs.find { |job| job[:job] == IndexOperationalLogEventJob }[:queue]).to eq("default")
  end

  it "ingests request and active job notification payloads with structured identifiers" do
    run = Factories.job(repository: repository, user: user).initial_run
    Thread.current[:syrus_current_run] = run

    described_class.ingest_request(
      {
        request_id: "req-2",
        method: "GET",
        path: "/api/v1/app/jobs",
        controller: "Api::V1::App::JobsController",
        action: "index",
        status: 200
      },
      12.34
    )
    described_class.ingest_job({ job: RunJob.new }, 45.67)

    expect(OperationalLogEvent.pluck(:source)).to contain_exactly("action_controller", "active_job")
    expect(OperationalLogEvent.find_by(source: "action_controller")).to have_attributes(request_id: "req-2", role: "web")
    expect(OperationalLogEvent.find_by(source: "active_job")).to have_attributes(
      job_id: run.job_id,
      workflow_id: run.workflow_id,
      run_id: run.id,
      role: "worker"
    )
  ensure
    Thread.current[:syrus_current_run] = nil
  end

  it "does not touch the search database during primary ingest" do
    allow(SearchRecord).to receive(:connection).and_raise("compute worker must not write search")

    expect {
      described_class.ingest(level: "info", source: "spec", message: "primary only")
    }.to change(OperationalLogEvent, :count).by(1)
  end

  it "prunes expired primary and search rows without logging recursively" do
    old_event = OperationalLogEvent.create!(
      occurred_at: 7.hours.ago,
      level: "info",
      role: "worker",
      hostname: "host-a",
      source: "spec",
      message: "expired event",
      context: {}
    )
    prepare_search_tables
    OperationalLogIndex.upsert(old_event)
    allow(Rails.logger).to receive(:warn)

    PruneOperationalLogsJob.perform_now(6.hours.ago)

    expect(OperationalLogEvent.exists?(old_event.id)).to be(false)
    expect(OperationalLogIndex.search(query: "expired", since: 12.hours.ago)).to be_empty
    expect(Rails.logger).not_to have_received(:warn)
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS operational_log_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE operational_log_fts
      USING fts5(
        message,
        context_text,
        context_json UNINDEXED,
        operational_log_event_id UNINDEXED,
        occurred_at UNINDEXED,
        level UNINDEXED,
        role UNINDEXED,
        hostname UNINDEXED,
        app_revision UNINDEXED,
        pid UNINDEXED,
        source UNINDEXED,
        job_id UNINDEXED,
        workflow_id UNINDEXED,
        run_id UNINDEXED,
        request_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
