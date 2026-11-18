require "rails_helper"

RSpec.describe PluginJob, :reset_plugin_registry do
  before do
    Syrus::PluginRegistry.register(name: "sample_plugin", version: "1.0.0")
    stub_const("SamplePluginJob", Class.new(described_class) do
      plugin_name "sample_plugin"

      def perform(fail_job = false)
        raise "broken plugin job" if fail_job
      end
    end)
  end

  it "routes plugin jobs to a queue named for the plugin by default" do
    expect(SamplePluginJob.new.queue_name).to eq("plugin_sample_plugin")
  end

  it "does not change the queue for core jobs" do
    expect(ApplicationJob.new.queue_name).to eq("control_plane")
  end

  it "allows an explicit queue override" do
    job_class = Class.new(described_class) do
      plugin_name "sample_plugin"
      queue_as :indexing
    end

    expect(job_class.new.queue_name).to eq("indexing")
  end

  it "uses the plugin manifest concurrency override" do
    Syrus::PluginRegistry.register(name: "wide_plugin", version: "1.0.0", job_concurrency: 7)
    job_class = Class.new(described_class) { plugin_name "wide_plugin" }

    expect(job_class.concurrency_limit).to eq(7)
    expect(job_class.new.concurrency_key).to eq("PluginJob/plugin:wide_plugin")
  end

  it "records and discards a repeatedly failing plugin job after bounded retries" do
    job = SamplePluginJob.new(true)
    job.exception_executions[[ StandardError ].to_s] = 4

    expect { job.perform_now }.not_to raise_error

    record = PluginRecord.find_by!(name: "sample_plugin")
    expect(record.plugin_job_failure_count).to eq(1)
    expect(record.plugin_job_last_error).to eq("RuntimeError: broken plugin job")
    expect(record.plugin_job_last_failed_at).to be_present
  end
end
