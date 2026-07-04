class CreatePrReviewComments < ActiveRecord::Migration[8.1]
  def up
    create_table :pr_review_comments, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: true
      t.string :pr_type, null: false
      t.string :comment_kind, null: false
      t.bigint :github_comment_id, null: false
      t.string :github_handle
      t.string :attributed_to
      t.boolean :actionable
      t.text :body
      t.datetime :actioned_at
      t.string :actioned_by
      t.datetime :comment_created_at
      t.timestamps
    end

    unless index_exists?(:pr_review_comments, [ :job_id, :pr_type, :comment_kind, :github_comment_id ])
      add_index :pr_review_comments, [ :job_id, :pr_type, :comment_kind, :github_comment_id ],
                unique: true,
                name: "index_pr_review_comments_uniqueness"
    end

    add_index :pr_review_comments, :actioned_at unless index_exists?(:pr_review_comments, :actioned_at)
  end

  def down
    drop_table :pr_review_comments, if_exists: true
  end
end
