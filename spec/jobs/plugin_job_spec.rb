require "rails_helper"

RSpec.describe PluginJob do
  before do
    stub_const("ExamplePluginJob", Class.new(described_class) do
      plugin :example_plugin
      def perform(*) = nil
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
      plugin :example_plugin, concurrency: 7
    end)

    expect(ParallelPluginJob.concurrency_limit).to eq(7)
    expect(ParallelPluginJob.concurrency_group.call).to eq("plugin_example_plugin")
  end

  it "retries ordinary failures with backoff and records the final discard" do
    record = PluginRecord.create!(name: "example_plugin", enabled: true, config: {})
    error = RuntimeError.new("broken")

    expect(ExamplePluginJob.rescue_handlers).to include([ "StandardError", anything ])
    ExamplePluginJob.new.record_discarded_failure(error)

    expect(record.reload.config.fetch("job_health")).to include(
      "discarded_count" => 1,
      "last_error" => "ExamplePluginJob: RuntimeError: broken"
    )
  end
end
