require "rails_helper"

RSpec.describe DeadWorkerQueueDetector do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    run.update!(state: "queued", started_at: nil)
  end

  after { clear_solid_queue_test_tables! }

  def ready_job(queue:, created_at: 10.minutes.ago)
    SolidQueue::Job.create!(
      class_name: "RunJob", queue_name: queue,
      arguments: JSON.generate("arguments" => [ run.id ]),
      created_at: created_at, updated_at: created_at
    ).tap do |queue_job|
      SolidQueue::ReadyExecution.create!(job: queue_job, queue_name: queue, priority: 0, created_at: created_at)
    end
  end

  it "returns bounded repair evidence for an aged queue with no live consumer" do
    ready_job(queue: "worker-gone")
    allow(InstanceVersion).to receive(:worker_queue_live?).with("worker-gone").and_return(false)

    result = described_class.call(run_ids: [ run.id ]).sole

    expect(result.to_h).to include(
      job_id: job.id, workflow_id: run.workflow.id, run_id: run.id,
      queue_name: "worker-gone", claim_state: "ready", run_state: "queued",
      workflow_affinity_present: false
    )
    expect(result.age_seconds).to be >= 599
  end

  it "excludes new queue rows and queues with live consumers" do
    ready_job(queue: "worker-live", created_at: 1.minute.ago)
    allow(InstanceVersion).to receive(:worker_queue_live?).with("worker-live").and_return(true)

    expect(described_class.call(run_ids: [ run.id ])).to be_empty
  end
end
