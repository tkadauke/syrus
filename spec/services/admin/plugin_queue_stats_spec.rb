require "rails_helper"

RSpec.describe Admin::PluginQueueStats, :reset_plugin_registry do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  it "reports queue depth and failure counts per plugin" do
    Syrus::PluginRegistry.register(name: "reports", version: "1.0.0")
    SolidQueue::Job.create!(class_name: "ReportsJob", queue_name: "plugin_reports", priority: 0, arguments: {})
    failed = SolidQueue::Job.create!(class_name: "ReportsJob", queue_name: "plugin_reports", priority: 0, arguments: {})
    SolidQueue::FailedExecution.create!(job: failed, error: { "message" => "boom" })

    expect(described_class.call.find { |stats| stats[:plugin] == "reports" })
      .to include(plugin: "reports", queue_name: "plugin_reports", depth: 1, failure_count: 1)
  end
end
