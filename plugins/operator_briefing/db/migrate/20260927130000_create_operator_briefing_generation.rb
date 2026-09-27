class CreateOperatorBriefingGeneration < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_briefing_briefings, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: false, index: { unique: true }
      t.references :repository, null: false, foreign_key: false
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.datetime :window_start
      t.datetime :window_end

      t.timestamps
    end

    unless index_exists?(:operator_briefing_briefings, [ :owner_user_id, :repository_id, :created_at ], name: "idx_operator_briefings_owner_repo_created")
      add_index :operator_briefing_briefings,
                [ :owner_user_id, :repository_id, :created_at ],
                name: "idx_operator_briefings_owner_repo_created"
    end

    create_table :operator_briefing_revisions, if_not_exists: true do |t|
      t.references :briefing, null: false, foreign_key: { to_table: :operator_briefing_briefings }
      t.integer :revision_number, null: false
      t.datetime :generated_at, null: false
      t.json :content_blocks
      t.references :generation_run, foreign_key: { to_table: :runs }

      t.timestamps
    end

    unless index_exists?(:operator_briefing_revisions, [ :briefing_id, :revision_number ], name: "idx_operator_briefing_revisions_number")
      add_index :operator_briefing_revisions,
                [ :briefing_id, :revision_number ],
                unique: true,
                name: "idx_operator_briefing_revisions_number"
    end

    create_table :operator_briefing_subscriptions, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    unless index_exists?(:operator_briefing_subscriptions, [ :user_id, :repository_id ], name: "idx_operator_briefing_subscriptions_identity")
      add_index :operator_briefing_subscriptions,
                [ :user_id, :repository_id ],
                unique: true,
                name: "idx_operator_briefing_subscriptions_identity"
    end

    create_table :operator_briefing_settings, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :cadence_expression, null: false
      t.boolean :budget_check_enabled, null: false, default: false
      t.string :agent_provider
      t.datetime :last_scheduled_at

      t.timestamps
    end

    unless column_exists?(:operator_briefing_items, :briefing_id)
      add_reference :operator_briefing_items, :briefing, type: :integer, foreign_key: { to_table: :operator_briefing_briefings }
    end
  end
end
