class CreateDiffReviewComments < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:diff_review_comments)
      create_table :diff_review_comments do |t|
        t.references :job, null: false, foreign_key: false
        t.references :user, null: false, foreign_key: false
        t.references :workflow, foreign_key: false
        t.references :run, foreign_key: false
        t.string :surface, null: false, default: "job_diff"
        t.string :base_ref
        t.string :head_ref
        t.string :path, null: false
        t.string :side, null: false
        t.integer :old_line
        t.integer :new_line
        t.text :diff_hunk
        t.json :context, null: false
        t.text :body, null: false
        t.string :state, null: false, default: "draft"
        t.datetime :submitted_at
        t.datetime :resolved_at
        t.datetime :superseded_at
        t.timestamps
      end
    end

    # The prefix lengths below are load-bearing. Without them MySQL computes
    # 8 + 1020 + 1020 + 1020 + 8 = 3076 bytes for this key against a
    # 3072-byte limit and refuses the index -- four bytes over. SQLite
    # (dev/test) has no such limit, so it only ever fails in production.
    #
    # `surface` and `state` are enums (`job_diff`; draft/submitted/resolved/
    # superseded -- 11 characters at the longest), so 32 is generous and loses
    # no selectivity, while `path` stays indexed in full because exact path
    # lookups are what this index is for.
    surface_path_state_index = [ :job_id, :surface, :path, :state, :id ]
    unless index_exists?(:diff_review_comments, surface_path_state_index, name: "idx_diff_review_comments_job_surface_path_state")
      add_index :diff_review_comments,
        surface_path_state_index,
        name: "idx_diff_review_comments_job_surface_path_state",
        length: { surface: 32, state: 32 }
    end

    line_anchor_index = [ :job_id, :path, :side, :old_line, :new_line ]
    unless index_exists?(:diff_review_comments, line_anchor_index, name: "idx_diff_review_comments_line_anchor")
      add_index :diff_review_comments,
        line_anchor_index,
        name: "idx_diff_review_comments_line_anchor"
    end
  end
end
