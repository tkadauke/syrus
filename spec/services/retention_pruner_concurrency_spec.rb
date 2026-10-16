require "rails_helper"

RSpec.describe "RetentionPruner concurrency" do
  self.use_transactional_tests = false

  before do
    Notification.delete_all
    @user = User.create!(
      email_address: "retention-pruner-concurrency@example.com",
      password: "supersecret"
    )
  end

  after do
    Notification.delete_all
    @user&.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "gives overlapping pruners ownership of distinct batches" do
    notifications = 2.times.map do |index|
      Notification.create!(user: @user, kind: "job_failed", body: "Old #{index}", created_at: 31.days.ago)
    end
    first_archive_entered = Queue.new
    release_first_archive = Queue.new
    archive_calls = Queue.new
    call_count = 0
    call_count_lock = Mutex.new

    allow(RetentionArchiver).to receive(:call) do |scope:, **|
      archive_calls << scope.pluck(:id)
      first = call_count_lock.synchronize do
        call_count += 1
        call_count == 1
      end
      if first
        first_archive_entered << true
        release_first_archive.pop
      end
    end

    errors = Queue.new
    results = Queue.new
    first = prune_in_thread(errors, results)
    first_archive_entered.pop
    second = prune_in_thread(errors, results)

    # Keep the first transaction inside archive long enough for the second
    # connection to contend for a batch. Without a claim/serialization guard,
    # both connections select and archive the same lowest primary key here.
    sleep 0.1
    release_first_archive << true
    [ first, second ].each(&:join)
    raise errors.pop unless errors.empty?

    archived_ids = 2.times.flat_map { archive_calls.pop }
    expect(archived_ids).to contain_exactly(*notifications.map(&:id))
    expect(2.times.map { results.pop }).to contain_exactly(1, 1)
    expect(Notification.where(id: notifications.map(&:id))).to be_empty
  end

  def prune_in_thread(errors, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << RetentionPruner.call(
          scope: Notification.prunable,
          retention_key: :run_diagnostic,
          cutoff: Notification.retention_cutoff,
          batch_size: 1,
          max_batches: 1
        )
      rescue StandardError => e
        errors << e
      end
    end
  end
end
