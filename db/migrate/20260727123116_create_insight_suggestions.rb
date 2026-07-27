class CreateInsightSuggestions < ActiveRecord::Migration[8.1]
  def up
    create_table :insight_suggestions, if_not_exists: true do |t|
      t.references :job,         null: false, foreign_key: true, index: true
      t.references :repository,  null: false, foreign_key: true, index: true
      t.references :created_job, null: true,  foreign_key: { to_table: :jobs }

      t.string  :title,          null: false
      t.string  :category,       null: false
      t.string  :severity,       null: false, default: "medium"
      t.float   :confidence,     null: false, default: 0.5
      t.string  :state,          null: false, default: "pending"

      t.text    :suggested_prompt
      t.text    :memory_suggestion

      t.datetime :accepted_at
      t.datetime :dismissed_at

      t.timestamps
    end

    # JSON columns cannot have a default value on MySQL 8.
    # Add the column nullable first, then tighten nullability via a backfill.
    add_column :insight_suggestions, :evidence, :json unless column_exists?(:insight_suggestions, :evidence)

    unless index_exists?(:insight_suggestions, :state)
      add_index :insight_suggestions, :state
    end
    unless index_exists?(:insight_suggestions, [ :repository_id, :created_at ],
                         name: "index_insight_suggestions_on_repository_id_and_created_at")
      add_index :insight_suggestions, [ :repository_id, :created_at ],
                name: "index_insight_suggestions_on_repository_id_and_created_at"
    end
  end

  def down
    drop_table :insight_suggestions, if_exists: true
  end
end
