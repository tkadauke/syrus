require "rails_helper"

RSpec.describe TestInsights::GraderNameBackfill do
  let(:job) { Factories.job }
  let(:repository) { job.repository }
  let(:test_run) do
    TestInsights::TestRun.create!(
      run: job.initial_run, repository: repository, grader_name: "rspec",
      total_count: 2, passed_count: 2, failed_count: 0, skipped_count: 0, error_count: 0
    )
  end

  def create_case!
    TestInsights::TestCase.create!(
      test_run: test_run, repository: repository, name: "example", suite_name: "Suite",
      status: "passed", duration_ms: 100
    )
  end

  it "backfills bounded batches resumably and idempotently" do
    first = create_case!
    second = create_case!

    first_batch = described_class.new.call(limit: 1)
    expect(first_batch).to have_attributes(done: false, processed: 1, next_after_id: first.id)
    expect(first.reload.grader_name).to eq("rspec")
    expect(second.reload.grader_name).to be_nil

    second_batch = described_class.new.call(after_id: first_batch.next_after_id, limit: 1)
    expect(second_batch).to have_attributes(done: false, processed: 1, next_after_id: second.id)
    expect(second.reload.grader_name).to eq("rspec")

    final_batch = described_class.new.call(after_id: second_batch.next_after_id, limit: 1)
    expect(final_batch).to have_attributes(done: true, processed: 0)
    expect { described_class.new.call(limit: 10) }.not_to change { TestInsights::TestCase.pluck(:grader_name) }
  end

  # Taking the next N unfilled cases needed ORDER BY ... LIMIT across the
  # join, which MySQL ran as a temporary table and filesort over all history.
  it "reads each batch as a bounded primary-key window, not an ordered limit across the join" do
    first = create_case!
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql].to_s }
    described_class.new.call(after_id: first.id - 1, limit: 500)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    batch_query = queries.find { |sql| sql.include?("test_insight_runs") && sql.start_with?("SELECT") }
    expect(batch_query).to include("BETWEEN")
    expect(batch_query).not_to match(/ORDER BY|LIMIT/i)
    expect(first.reload.grader_name).to eq("rspec")
  end

  it "skips a gap in the id space in one step" do
    early = create_case!
    late = create_case!
    late.update_columns(id: early.id + 10_000)

    first_batch = described_class.new.call(limit: 1)
    second_batch = described_class.new.call(after_id: first_batch.next_after_id, limit: 1)

    expect(second_batch).to have_attributes(done: false, processed: 1, next_after_id: early.id + 10_000)
    expect(TestInsights::TestCase.find(early.id + 10_000).grader_name).to eq("rspec")
  end

  it "detects remaining work in a range without joining test runs" do
    filled = create_case!
    unfilled = create_case!
    filled.update_columns(grader_name: "rspec")

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql].to_s }
    pending = described_class.pending_in_range?(after_id: 0, up_to_id: unfilled.id)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(pending).to be(true)
    expect(described_class.pending_in_range?(after_id: unfilled.id, up_to_id: unfilled.id)).to be(false)
    expect(described_class.pending_in_range?(after_id: 0, up_to_id: filled.id)).to be(false)
    expect(queries.join("\n")).not_to include("test_insight_runs")
    expect(queries.join("\n")).not_to include("COUNT")
  end

  it "honors a captured upper bound while live ingestion creates newer rows" do
    historical = create_case!
    upper_bound = described_class.max_test_case_id
    live = create_case!

    result = described_class.new.call(up_to_id: upper_bound, limit: 10)

    expect(result.processed).to eq(1)
    expect(historical.reload.grader_name).to eq("rspec")
    expect(live.reload.grader_name).to be_nil
  end
end
