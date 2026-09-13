class AddDiffReviewVersionsSourceDiffLookupIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :diff_review_versions,
      [ :job_id, :reason, :version_index, :id ],
      name: "idx_diff_review_versions_job_reason_latest",
      if_not_exists: true
  end
end
