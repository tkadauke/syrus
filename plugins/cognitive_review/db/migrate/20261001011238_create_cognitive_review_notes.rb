class CreateCognitiveReviewNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :cognitive_review_notes, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.references :run, null: false, foreign_key: true
      t.references :diff_review_version, null: false, foreign_key: true
      t.references :acknowledged_by_user, foreign_key: { to_table: :users }
      t.references :discussion_started_by_user, foreign_key: { to_table: :users }
      t.references :last_discussed_by_user, foreign_key: { to_table: :users }

      t.string :path, null: false
      t.string :side, null: false
      t.integer :start_line, null: false
      t.integer :end_line, null: false
      t.integer :old_start_line
      t.integer :old_end_line
      t.integer :new_start_line
      t.integer :new_end_line
      t.string :title, null: false
      t.string :summary
      t.text :explanation, null: false
      t.json :reason_codes, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.string :priority, default: "medium", null: false
      t.json :source_metadata, null: false
      t.string :state, default: "open", null: false
      t.string :idempotency_key, null: false
      t.datetime :acknowledged_at
      t.datetime :discussion_started_at
      t.datetime :last_discussed_at
      t.timestamps
    end

    add_index :cognitive_review_notes,
      %i[run_id diff_review_version_id idempotency_key],
      unique: true,
      name: "idx_cognitive_review_notes_idempotency",
      if_not_exists: true
    add_index :cognitive_review_notes,
      %i[job_id diff_review_version_id state path id],
      name: "idx_cognitive_review_notes_job_version_state",
      if_not_exists: true
    add_index :cognitive_review_notes,
      %i[job_id path side start_line end_line],
      name: "idx_cognitive_review_notes_range",
      if_not_exists: true

    create_table :cognitive_review_discussion_entries, if_not_exists: true do |t|
      t.references :note, null: false, foreign_key: { to_table: :cognitive_review_notes }
      t.references :user, foreign_key: true
      t.text :body, null: false
      t.json :metadata, null: false
      t.timestamps
    end

    add_index :cognitive_review_discussion_entries,
      %i[note_id created_at id],
      name: "idx_cognitive_review_discussions_note_order",
      if_not_exists: true
  end
end
