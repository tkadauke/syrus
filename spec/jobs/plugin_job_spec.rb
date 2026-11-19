require "rails_helper"

RSpec.describe PluginJob do
  include ActiveJob::TestHelper

  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  before do
    stub_const("ExamplePluginJob", Class.new(described_class) do
      plugin :example_plugin
      def perform(*) = nil
    end)
    stub_const("FailingPluginJob", Class.new(described_class) do
      plugin :example_plugin
      def perform = raise("broken")
    end)
  end

  it "places plugin jobs on a per-plugin queue without changing core jobs" do
    expect(ExamplePluginJob.new.queue_name).to eq("plugin_example_plugin")
    expect(ApplicationJob.new.queue_name).to eq("control_plane")
  end

  it "allows a job to override its queue" do
    stub_const("SpecialPluginJob", Class.new(described_class) do
      plugin :example_plugin
      queue_as :videos
    end)

    expect(SpecialPluginJob.new.queue_name).to eq("videos")
  end

  it "allows a plugin to raise its shared concurrency cap" do
    stub_const("ParallelPluginJob", Class.new(described_class) do
      plugin :example_plugin, concurrency: 7, concurrency_duration: 30.minutes
    end)

    expect(ParallelPluginJob.concurrency_limit).to eq(7)
    expect(ParallelPluginJob.concurrency_group.call).to eq("plugin_example_plugin")
    expect(ParallelPluginJob.concurrency_duration).to eq(30.minutes)
  end

  it "uses a renewable lease longer than Solid Queue's default" do
    job = ExamplePluginJob.new
    semaphore = SolidQueue::Semaphore.create!(
      key: job.concurrency_key, value: 1, expires_at: 1.minute.from_now,
      created_at: Time.current, updated_at: Time.current
    )

    expect(ExamplePluginJob.concurrency_duration).to eq(PluginJob::DEFAULT_CONCURRENCY_DURATION)
    expect(ExamplePluginJob.concurrency_duration).to be > SolidQueue.default_concurrency_control_period

    described_class.renew_concurrency_lease(job)

    expect(semaphore.reload.expires_at).to be_within(1.second).of(ExamplePluginJob.concurrency_duration.from_now)
  end

  it "retries ordinary failures with backoff and records the final discard" do
    record = PluginRecord.create!(name: "example_plugin", enabled: true, config: {})
    started_at = Time.current

    expect { FailingPluginJob.perform_now }.to have_enqueued_job(FailingPluginJob).on_queue("plugin_example_plugin")
    scheduled_at = Time.at(enqueued_jobs.last.fetch(:at))
    expect(scheduled_at).to be_between(started_at + 2.seconds, Time.current + 4.seconds)
    expect(record.reload.config["job_health"]).to be_nil

    clear_enqueued_jobs
    final_attempt = FailingPluginJob.new
    final_attempt.exception_executions = { [ StandardError ].to_s => PluginJob::DEFAULT_ATTEMPTS - 1 }
    expect { final_attempt.perform_now }.not_to have_enqueued_job(FailingPluginJob)

    expect(record.reload.config.fetch("job_health")).to include(
      "discarded_count" => 1,
      "last_error" => "FailingPluginJob: RuntimeError: broken"
    )
  end
end
