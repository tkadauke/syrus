require "rails_helper"

RSpec.describe RunQueueDiagnosis do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial", state: "queued") }

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
  end

  after { clear_solid_queue_test_tables! }

  def queue_job(queue: "runs", run_id: run.id)
    SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: queue,
      arguments: JSON.generate("arguments" => [ run_id ]),
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def worker(queues: "runs", threads: 1)
    SolidQueue::Process.create!(
      hostname: "worker-a",
      kind: "Worker",
      name: "worker-a-1",
      pid: 123,
      last_heartbeat_at: Time.current,
      metadata: { "queues" => queues, "thread_pool_size" => threads }
    )
  end

  it "reports a ready RunJob whose consuming worker threads are occupied" do
    queued = queue_job
    process = worker
    SolidQueue::ReadyExecution.create!(job: queued, queue_name: "runs", priority: 0, created_at: Time.current)
    other_job = queue_job(run_id: run.id + 10_000)
    SolidQueue::ClaimedExecution.create!(job: other_job, process_id: process.id, created_at: Time.current)

    expect(described_class.call(run)).to include(kind: "ready_waiting_for_slot", details: include(queue_name: "runs", live_worker_count: 1))
  end

  it "reports a ready RunJob on a queue with no consumer" do
    queued = queue_job(queue: "resume-storage-a")
    worker(queues: "runs")
    SolidQueue::ReadyExecution.create!(job: queued, queue_name: queued.queue_name, priority: 0, created_at: Time.current)

    expect(described_class.call(run)).to include(kind: "ready_no_consumer", details: include(live_worker_queues: [ "runs" ]))
  end

  it "reports a concurrency-blocked RunJob" do
    queued = queue_job
    SolidQueue::BlockedExecution.insert_all!([ { job_id: queued.id, queue_name: "runs", concurrency_key: "job-#{job.id}", expires_at: 1.minute.from_now, created_at: Time.current } ])

    expect(described_class.call(run)[:kind]).to eq("concurrency_blocked")
  end

  it "reports a future scheduled RunJob" do
    queued = queue_job
    scheduled_at = 5.minutes.from_now.change(usec: 0)
    SolidQueue::ScheduledExecution.insert_all!([ { job_id: queued.id, queue_name: "runs", priority: 0, scheduled_at: scheduled_at, created_at: Time.current } ])

    expect(described_class.call(run)).to include(kind: "scheduled", details: include(scheduled_at: scheduled_at.iso8601))
  end

  it "reports an overdue scheduled RunJob as unknown" do
    queued = queue_job
    scheduled_at = 5.minutes.ago.change(usec: 0)
    SolidQueue::ScheduledExecution.insert_all!([ { job_id: queued.id, queue_name: "runs", priority: 0, scheduled_at: scheduled_at, created_at: 10.minutes.ago } ])

    expect(described_class.call(run)).to include(kind: "unknown", details: include(scheduled_at: scheduled_at.iso8601))
  end

  it "reports a claimed RunJob that has not started" do
    queued = queue_job
    SolidQueue::ClaimedExecution.create!(job: queued, process_id: worker.id, created_at: Time.current)

    expect(described_class.call(run)[:kind]).to eq("claimed_not_started")
  end

  it "reports a queued Run with no RunJob" do
    expect(described_class.call(run)[:kind]).to eq("no_run_job")
  end

  it "reports a ready RunJob when no worker heartbeat is live" do
    queued = queue_job
    SolidQueue::ReadyExecution.create!(job: queued, queue_name: "runs", priority: 0, created_at: Time.current)

    expect(described_class.call(run)[:kind]).to eq("no_live_workers")
  end

  it "prefers the workflow start-blocked reason" do
    workflow.update!(artifacts: { "start_blocked_reason" => "no_capable_worker", "start_blocked_details" => { "queue_name" => "runs-macos-arm64" } })

    expect(described_class.call(run)).to include(kind: "start_blocked", details: include(reason: "no_capable_worker"))
  end

  it "falls back to unknown when Solid Queue tables are unavailable" do
    allow(SolidQueue::Job).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "missing table")

    expect(described_class.call(run)[:kind]).to eq("unknown")
  end
end
