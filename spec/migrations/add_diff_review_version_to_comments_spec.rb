require "rails_helper"
require Rails.root.join("db/migrate/20260908083000_add_diff_review_version_to_comments")

RSpec.describe AddDiffReviewVersionToComments, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  around do |example|
    migration.down if connection.column_exists?(:diff_review_comments, :diff_review_version_id)
    reset_diff_review_comment_columns
    example.run
  ensure
    migration.up unless connection.column_exists?(:diff_review_comments, :diff_review_version_id)
    reset_diff_review_comment_columns
  end

  it "backfills legacy comments to an existing version with matching stored refs" do
    version = create_version(job: job, index: 1, base_sha: "base-sha", head_sha: "head-sha")
    comment_id = insert_legacy_comment(job: job, base_ref: "base-sha", head_ref: "head-sha")

    migration.up
    reset_diff_review_comment_columns

    expect(DiffReviewComment.find(comment_id).diff_review_version_id).to eq(version.id)
  end

  it "creates a legacy version from stored refs when no job version exists" do
    comment_id = insert_legacy_comment(job: job, base_ref: "legacy-base", head_ref: "legacy-head")

    migration.up
    reset_diff_review_comment_columns

    comment = DiffReviewComment.find(comment_id)
    version = comment.diff_review_version
    expect(version).to have_attributes(
      job_id: job.id,
      base_sha: "legacy-base",
      head_sha: "legacy-head",
      label: "Legacy diff review",
      reason: "diff_review_comment_backfill"
    )
    expect(version.metadata).to include("backfilled_from_diff_review_comment_id" => comment_id)
  end

  private

  def create_version(job:, index:, base_sha:, head_sha:)
    DiffReviewVersion.create!(
      job: job,
      version_index: index,
      base_sha: base_sha,
      head_sha: head_sha,
      source_key: "spec:#{job.id}:#{index}",
      files_snapshot: [],
      metadata: {}
    )
  end

  def insert_legacy_comment(job:, base_ref:, head_ref:)
    now = connection.quote(Time.current)
    connection.insert(<<~SQL.squish)
      INSERT INTO diff_review_comments
        (job_id, user_id, surface, base_ref, head_ref, anchor_kind, path, side, new_line, context, body, state, created_at, updated_at)
      VALUES
        (#{job.id}, #{user.id}, 'job_source_diff', #{connection.quote(base_ref)}, #{connection.quote(head_ref)}, 'line', 'app/models/widget.rb', 'right', 12, '{}', 'Please tighten this up.', 'draft', #{now}, #{now})
    SQL
  end

  def reset_diff_review_comment_columns
    connection.schema_cache.clear!
    DiffReviewComment.reset_column_information
    described_class::MigrationDiffReviewComment.reset_column_information
    described_class::MigrationDiffReviewVersion.reset_column_information
  end
end
