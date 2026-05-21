require "rails_helper"

RSpec.describe Admin::Queue::Filter do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  def sq_job(class_name:, queue_name:, created_at: Time.current)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: { "arguments" => [] },
      created_at: created_at,
      updated_at: created_at
    )
  end

  def filter_for(tree, tab: :active)
    described_class.from_params(
      { Filters::QueryParam::PARAM_NAME => Filters::QueryParam.encode(tree) },
      tab: tab
    )
  end

  it "filters SolidQueue::Job rows by queue_name" do
    runs = sq_job(class_name: "RunJob", queue_name: "runs")
    sq_job(class_name: "ChatTurnJob", queue_name: "chat")

    tree = { "and" => [ { "field" => "queue_name", "op" => "is", "value" => "runs" } ] }

    expect(filter_for(tree).apply(SolidQueue::Job.all)).to contain_exactly(runs)
  end

  it "filters SolidQueue::Job rows by job_class" do
    run_job = sq_job(class_name: "RunJob", queue_name: "runs")
    sq_job(class_name: "ChatTurnJob", queue_name: "chat")

    tree = { "and" => [ { "field" => "job_class", "op" => "is", "value" => "RunJob" } ] }

    expect(filter_for(tree).apply(SolidQueue::Job.all)).to contain_exactly(run_job)
  end

  it "defaults the failed tab to failures from the last 24 hours" do
    travel_to Time.zone.local(2026, 5, 21, 12, 0, 0) do
      recent = sq_job(class_name: "RunJob", queue_name: "runs")
      old = sq_job(class_name: "RunJob", queue_name: "runs")
      SolidQueue::FailedExecution.create!(job: recent, created_at: 23.hours.ago, error: {})
      SolidQueue::FailedExecution.create!(job: old, created_at: 25.hours.ago, error: {})

      filter = described_class.from_params({}, tab: :failed)

      expect(filter.to_h).to eq(described_class.default_tree(:failed))
      expect(filter.apply(SolidQueue::FailedExecution.includes(:job))).to contain_exactly(recent.failed_execution)
    end
  end
end
