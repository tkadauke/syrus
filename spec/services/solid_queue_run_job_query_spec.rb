require "rails_helper"

RSpec.describe SolidQueueRunJobQuery do
  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
  end

  after do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  def queue_job(arguments)
    SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: "runs",
      priority: 0,
      arguments: JSON.generate("arguments" => arguments),
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  it "matches integer and GlobalID arguments without matching substrings" do
    integer = queue_job([ 12 ])
    global_id = queue_job([ { "_aj_globalid" => "gid://syrus/Run/12" } ])
    queue_job([ 123 ])
    queue_job([ "prefix-12-suffix" ])

    matches = described_class.matching(scope: SolidQueue::Job.all, run_id: 12)

    expect(matches.map(&:id)).to contain_exactly(integer.id, global_id.id)
  end
end
