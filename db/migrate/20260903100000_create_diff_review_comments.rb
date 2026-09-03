class CreateDiffReviewComments < ActiveRecord::Migration[8.1]
  def change
    create_table :diff_review_comments do |t|
      t.references :job, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :workflow, foreign_key: true
      t.references :run, foreign_key: true
      t.string :surface, null: false, default: "job_diff"
      t.string :base_ref
      t.string :head_ref
      t.string :path, null: false
      t.string :side, null: false
      t.integer :old_line
      t.integer :new_line
      t.text :diff_hunk
      t.json :context, null: false, default: {}
      t.text :body, null: false
      t.string :state, null: false, default: "draft"
      t.datetime :submitted_at
      t.datetime :resolved_at
      t.datetime :superseded_at
      t.timestamps
    end

    add_index :diff_review_comments,
      [ :job_id, :surface, :path, :state, :id ],
      name: "idx_diff_review_comments_job_surface_path_state"
    add_index :diff_review_comments,
      [ :job_id, :path, :side, :old_line, :new_line ],
      name: "idx_diff_review_comments_line_anchor"
  end
end
