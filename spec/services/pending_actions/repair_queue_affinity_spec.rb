require "rails_helper"

RSpec.describe PendingActions::RepairQueueAffinity do
  include ActiveJob::TestHelper

  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(state: "running", repository: repository, user: admin, agent_provider: "claude") }
  let(:workflow) do
    Workflow.create!(
      job: job,
      user: admin,
      trigger_kind: "manual",
      agent_provider: "claude",
      state: "running",
      worker_hostname: "dead-host",
      worker_storage_key: "dead-storage"
    )
  end
  let(:step) { workflow.steps.create!(kind: "manual", position: 0, iteration: 1) }
  let(:run) do
    Run.create!(
      job: job,
      user: admin,
      step: step,
      trigger_kind: "manual",
      agent_provider: "claude",
      state: "queued"
    )
  end

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    clear_enqueued_jobs
  end

  after do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  def pending_action_for(reason: "Affinity points at a worker that no longer exists.", target_run: run)
    ChatSession.create!(user: admin, repository: repository).pending_actions.create!(
      action: "repair_queue_affinity",
      requested_by: "agent",
      reason: reason,
      payload: { "job_id" => job.id, "run_id" => target_run.id }
    )
  end

  def solid_queue_run_job(target_run, queue_name: "resume-dead-storage")
    SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: queue_name,
      priority: 0,
      arguments: JSON.generate("arguments" => [ target_run.id ]),
      created_at: 10.minutes.ago,
      updated_at: 10.minutes.ago
    ).tap do |queue_job|
      SolidQueue::ReadyExecution.create!(
        job_id: queue_job.id,
        queue_name: queue_name,
        priority: 0,
        created_at: 10.minutes.ago
      )
    end
  end

  def live_worker!(queue_name:, hostname: "worker-live", storage_key: nil, capabilities: { "os" => [ "linux" ] })
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "worker",
      last_heartbeat_at: Time.current,
      metadata: {
        "hostname" => hostname,
        "worker_storage_key" => storage_key,
        "queues" => [ queue_name ],
        "capabilities" => capabilities
      }.compact,
      name: "#{hostname}:1",
      pid: 123,
      created_at: Time.current
    )
  end

  it "repairs a queued Run whose affinity no live worker satisfies and lets it start on a different worker" do
    stale_queue_job = solid_queue_run_job(run)
    action = pending_action_for

    expect {
      expect(action.confirm!(user: admin)).to be true
    }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

    expect(SolidQueue::Job.where(id: stale_queue_job.id)).to be_empty
    expect(SolidQueue::ReadyExecution.where(job_id: stale_queue_job.id)).to be_empty
    expect(workflow.reload.worker_hostname).to be_nil
    expect(workflow.worker_storage_key).to be_nil
    expect(JobLog.where(run: run).pluck(:chunk)).to include(a_string_matching(/repaired queue affinity/))

    allow(SyrusVersion).to receive(:hostname).and_return("worker-new")
    allow(WorkerStorageIdentity).to receive(:queue_key).and_return("new-storage")
    allow_any_instance_of(RunJob).to receive(:perform_step) do |run_job|
      started = run_job.instance_variable_get(:@run)
      started.start!
      started.save!
    end

    RunJob.perform_now(run.id)

    expect(run.reload).to be_running
    expect(workflow.reload.worker_hostname).to eq("worker-new")
    expect(workflow.worker_storage_key).to eq("new-storage")
  end

  it "refuses a Run that is not queued" do
    running_run = run
    running_run.update!(state: "running", started_at: Time.current)
    action = pending_action_for(target_run: running_run)

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /not queued/)
  end

  it "refuses when a live worker satisfies the current affinity" do
    live_worker!(queue_name: "resume-dead-storage", storage_key: "dead-storage")
    solid_queue_run_job(run)
    action = pending_action_for

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /live worker satisfying its affinity/)
  end

  it "refuses when a matching queue row is already claimed" do
    queue_job = solid_queue_run_job(run)
    SolidQueue::ReadyExecution.where(job_id: queue_job.id).delete_all
    process = live_worker!(queue_name: "resume-other-storage")
    SolidQueue::ClaimedExecution.create!(job_id: queue_job.id, process_id: process.id, created_at: Time.current)
    action = pending_action_for

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /claimed Solid Queue jobs/)
    expect(workflow.reload.worker_storage_key).to eq("dead-storage")
  end

  it "does not let an affinity re-stamp during repair leave the replacement wedged" do
    solid_queue_run_job(run)
    action = pending_action_for

    allow_any_instance_of(Run).to receive(:reenqueue!).and_wrap_original do |original, *args, **kwargs|
      workflow.update_columns(worker_hostname: "dead-host", worker_storage_key: "dead-storage")
      original.call(*args, **kwargs)
    end

    expect {
      expect(action.confirm!(user: admin)).to be true
    }.to have_enqueued_job(RunJob).with(run.id).on_queue("runs")

    expect(workflow.reload.worker_hostname).to be_nil
    expect(workflow.worker_storage_key).to be_nil
  end
end
