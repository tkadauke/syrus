class AddDiffReviewVersionToComments < ActiveRecord::Migration[8.1]
  class MigrationDiffReviewComment < ActiveRecord::Base
    self.table_name = "diff_review_comments"
  end

  class MigrationDiffReviewVersion < ActiveRecord::Base
    self.table_name = "diff_review_versions"
  end

  def up
    unless column_exists?(:diff_review_comments, :diff_review_version_id)
      add_reference :diff_review_comments, :diff_review_version, null: true, foreign_key: false, index: true
    end

    MigrationDiffReviewComment.reset_column_information
    MigrationDiffReviewVersion.reset_column_information
    backfill_comments

    change_column_null :diff_review_comments, :diff_review_version_id, false

    scoped_index = [ :job_id, :diff_review_version_id, :surface, :path, :state, :id ]
    unless index_exists?(:diff_review_comments, scoped_index, name: "idx_diff_review_comments_version_surface_path_state")
      add_index :diff_review_comments,
        scoped_index,
        name: "idx_diff_review_comments_version_surface_path_state",
        length: { surface: 32, state: 32 }
    end
  end

  def down
    if index_exists?(:diff_review_comments, name: "idx_diff_review_comments_version_surface_path_state")
      remove_index :diff_review_comments, name: "idx_diff_review_comments_version_surface_path_state"
    end

    remove_reference :diff_review_comments, :diff_review_version, foreign_key: false if column_exists?(:diff_review_comments, :diff_review_version_id)
  end

  private

  def backfill_comments
    MigrationDiffReviewComment.where(diff_review_version_id: nil).find_each do |comment|
      version = matching_version_for(comment) || latest_version_for(comment) || create_legacy_version_for(comment)
      raise ActiveRecord::IrreversibleMigration, "diff_review_comment #{comment.id} has no version and no stored refs to backfill from" unless version

      comment.update_columns(diff_review_version_id: version.id)
    end
  end

  def matching_version_for(comment)
    return nil if comment.base_ref.blank? || comment.head_ref.blank?

    MigrationDiffReviewVersion
      .where(job_id: comment.job_id)
      .where(
        "(base_sha = :base AND head_sha = :head) OR (base_ref = :base AND head_ref = :head)",
        base: comment.base_ref,
        head: comment.head_ref
      )
      .order(version_index: :desc, id: :desc)
      .first
  end

  def latest_version_for(comment)
    MigrationDiffReviewVersion.where(job_id: comment.job_id).order(version_index: :desc, id: :desc).first
  end

  def create_legacy_version_for(comment)
    return nil if comment.base_ref.blank? || comment.head_ref.blank?

    next_index = MigrationDiffReviewVersion.where(job_id: comment.job_id).maximum(:version_index).to_i + 1
    MigrationDiffReviewVersion.create!(
      job_id: comment.job_id,
      workflow_id: comment.workflow_id,
      run_id: comment.run_id,
      version_index: next_index,
      base_sha: comment.base_ref,
      head_sha: comment.head_ref,
      base_ref: comment.base_ref,
      head_ref: comment.head_ref,
      source_key: "legacy-diff-comment:#{comment.id}",
      trigger_kind: nil,
      label: "Legacy diff review",
      reason: "diff_review_comment_backfill",
      truncated: false,
      files_snapshot: [],
      metadata: { "backfilled_from_diff_review_comment_id" => comment.id },
      created_at: comment.created_at,
      updated_at: Time.current
    )
  end
end
