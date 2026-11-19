require "rails_helper"

RSpec.describe Admin::PluginJobHealth do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  def create_job(class_name:, queue_name:)
    SolidQueue::Job.create!(
      class_name:,
      queue_name:,
      priority: 0,
      arguments: { "arguments" => [] },
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  it "batches conventional, external, and overridden plugin queues by owner" do
    create_job(class_name: "ExternalPluginJob", queue_name: "plugin_external_example")
    create_job(class_name: "VideoWalkthroughs::AnalysisJob", queue_name: "videos")
    failed_video = create_job(class_name: "VideoWalkthroughs::AnalysisJob", queue_name: "videos")
    SolidQueue::FailedExecution.create!(job: failed_video, error: "broken", created_at: Time.current)

    health = described_class.new

    expect(health.for("video_walkthroughs", default_queue: "plugin_video_walkthroughs")).to eq(
      queue: "plugin_video_walkthroughs, videos",
      depth: 1,
      failed_count: 1
    )
    expect(health.summaries).to contain_exactly(
      { plugin: "external_example", queue: "plugin_external_example", depth: 1, failed_count: 0 },
      { plugin: "video_walkthroughs", queue: "videos", depth: 1, failed_count: 1 }
    )
  end

  it "uses two aggregate queries regardless of plugin count" do
    create_job(class_name: "ExternalOneJob", queue_name: "plugin_one")
    create_job(class_name: "ExternalTwoJob", queue_name: "plugin_two")

    queries = []
    subscriber = lambda do |*, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].match?(/solid_queue_(jobs|failed_executions)/)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      health = described_class.new
      health.for("one")
      health.for("two")
    end

    expect(queries.length).to eq(2)
  end
end
