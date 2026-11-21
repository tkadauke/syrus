module TestInsights
  # The suite-wide runtime profile one round of sharded grading splits its
  # spec files by. Every shard of a round must partition from identical input,
  # or a file can land in no shard or two; the live runtime summaries change as
  # shards finish, so the profile is captured once per round -- keyed by the
  # grader and the immutable source snapshot the round grades -- and reused by
  # every shard, including a shard retried within the same round.
  class ShardRuntimeSnapshot < ApplicationRecord
    self.table_name = "test_insight_shard_runtime_snapshots"

    # Long enough for a shard retried well after the rest of its round to
    # partition from the same profile the other shards used.
    RETAIN_FOR = 14.days

    belongs_to :repository

    scope :prunable, -> { where("created_at < ?", RETAIN_FOR.ago) }

    validates :grader_key, :source_snapshot_id, presence: true

    def self.fetch(repository:, grader_key:, source_snapshot_id:)
      find_by(repository: repository, grader_key: grader_key, source_snapshot_id: source_snapshot_id) ||
        create_or_find_by!(repository: repository, grader_key: grader_key, source_snapshot_id: source_snapshot_id) do |snapshot|
          snapshot.profile = yield
        end
    end
  end
end
