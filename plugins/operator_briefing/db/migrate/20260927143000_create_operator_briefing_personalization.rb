class CreateOperatorBriefingPersonalization < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_briefing_source_preferences, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: false
      t.string :source_key, null: false
      t.boolean :enabled, null: false, default: true
      t.float :weight, null: false, default: 1.0
      t.string :suggested_by, null: false, default: "system"
      t.datetime :confirmed_at

      t.timestamps
    end

    unless index_exists?(:operator_briefing_source_preferences, [ :user_id, :source_key, :confirmed_at ], name: "idx_operator_briefing_source_preferences_effective")
      add_index :operator_briefing_source_preferences,
                [ :user_id, :source_key, :confirmed_at ],
                name: "idx_operator_briefing_source_preferences_effective"
    end
    unless index_exists?(:operator_briefing_source_preferences, [ :user_id, :source_key, :suggested_by, :created_at ], name: "idx_operator_briefing_source_preferences_suggestions")
      add_index :operator_briefing_source_preferences,
                [ :user_id, :source_key, :suggested_by, :created_at ],
                name: "idx_operator_briefing_source_preferences_suggestions"
    end

    create_table :operator_briefing_feedbacks, if_not_exists: true do |t|
      t.references :briefing, foreign_key: false
      t.references :briefing_item, foreign_key: false
      t.references :user, null: false, foreign_key: false
      t.string :sentiment
      t.text :note
      t.float :weight, null: false, default: 0.65
      t.references :memory_entry, foreign_key: false

      t.timestamps
    end

    add_index :operator_briefing_feedbacks, :user_id unless index_exists?(:operator_briefing_feedbacks, :user_id)
    add_index :operator_briefing_feedbacks, :created_at unless index_exists?(:operator_briefing_feedbacks, :created_at)
  end
end
