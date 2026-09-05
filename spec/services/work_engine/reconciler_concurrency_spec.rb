require "rails_helper"

RSpec.describe "WorkEngine::Reconciler.call_locked!" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  around do |example|
    clear_enqueued_jobs
    example.run
    clear_enqueued_jobs
  end

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
  end

  after do
    clear_solid_queue_test_tables!
  end

  def enqueued_run_job_ids
    enqueued_jobs.select { |enqueued| enqueued["job_class"] == "RunJob" }.map { |enqueued| enqueued["arguments"].first }
  end

  # Regression coverage for the JOB-2970 / WF-18780 "run storm": two
  # concurrent reconcile passes read the same stale state (a queued Run with
  # no SolidQueue claim) and both independently decided to repair it,
  # re-enqueueing the same Run twice. WorkEngine::Reconciler.call_locked!
  # closes this by acquiring the exact SolidQueue semaphore key
  # WorkEngine::ReconcileJob's limits_concurrency guard uses, so a second
  # inline reconcile for the same Job cannot even start its own read/plan/
  # repair cycle while one is already in flight.
  it "does not evaluate or repair a Job while a concurrent reconcile already holds its lock" do
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    clear_enqueued_jobs

    concurrent_reconcile = WorkEngine::ReconcileJob.new(source: "other-worker", job_id: job.id)
    expect(SolidQueue::Semaphore.wait(concurrent_reconcile)).to eq(true)

    result = WorkEngine::Reconciler.call_locked!(source: "spec", job_id: job.id, execute_repairs: true)

    expect(result).to be_nil
    expect(run.reload.state).to eq("queued")
    expect(enqueued_run_job_ids).to be_empty

    SolidQueue::Semaphore.signal(concurrent_reconcile)

    result = WorkEngine::Reconciler.call_locked!(source: "spec", job_id: job.id, execute_repairs: true)

    expect(result).to be_a(WorkEngine::Reconciler::Result)
    expect(result.repair_executions.map(&:action)).to include("reenqueue_run")
    expect(enqueued_run_job_ids).to eq([ run.id ])
  end

  it "does not block reconciliation for an unrelated Job while another Job's lock is held" do
    other_job = Factories.job(agent_provider: "claude")

    concurrent_reconcile = WorkEngine::ReconcileJob.new(source: "other-worker", job_id: job.id)
    expect(SolidQueue::Semaphore.wait(concurrent_reconcile)).to eq(true)

    result = WorkEngine::Reconciler.call_locked!(source: "spec", job_id: other_job.id, execute_repairs: true)

    expect(result).to be_a(WorkEngine::Reconciler::Result)
  end

  it "releases the lock after a successful run so a subsequent call can acquire it" do
    result = WorkEngine::Reconciler.call_locked!(source: "spec", job_id: job.id, execute_repairs: true)
    expect(result).to be_a(WorkEngine::Reconciler::Result)

    still_locked = WorkEngine::ReconcileJob.new(source: "spec-check", job_id: job.id)
    expect(SolidQueue::Semaphore.wait(still_locked)).to eq(true)
    SolidQueue::Semaphore.signal(still_locked)
  end

  it "releases the lock even when the reconcile body raises" do
    allow(WorkEngine::Reconciler).to receive(:new).and_raise(RuntimeError, "boom")

    expect { WorkEngine::Reconciler.call_locked!(source: "spec", job_id: job.id, execute_repairs: true) }
      .to raise_error(RuntimeError, "boom")

    still_locked = WorkEngine::ReconcileJob.new(source: "spec-check", job_id: job.id)
    expect(SolidQueue::Semaphore.wait(still_locked)).to eq(true)
    SolidQueue::Semaphore.signal(still_locked)
  end

  it "falls back to running unlocked when the SolidQueue semaphore table is unavailable" do
    allow(SolidQueue::Semaphore).to receive(:wait).and_raise(ActiveRecord::StatementInvalid, "no such table: solid_queue_semaphores")
    allow(Rails.logger).to receive(:warn).and_call_original

    result = WorkEngine::Reconciler.call_locked!(source: "spec", job_id: job.id, execute_repairs: true)

    expect(result).to be_a(WorkEngine::Reconciler::Result)
    expect(Rails.logger).to have_received(:warn).with(/SolidQueue semaphore unavailable/)
  end
end
