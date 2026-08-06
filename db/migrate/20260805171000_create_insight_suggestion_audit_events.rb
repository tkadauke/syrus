class CreateInsightSuggestionAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :insight_suggestion_audit_events, if_not_exists: true do |t|
      t.references :insight_suggestion, null: false, foreign_key: true, index: true
      t.string :event_type, null: false
      t.string :actor_kind, null: false
      t.references :actor_user, null: true, foreign_key: { to_table: :users }, index: true
      t.references :actor_run, null: true, foreign_key: { to_table: :runs }, index: true
      t.json :previous_values
      t.json :new_values
      t.text :reason
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :insight_suggestion_audit_events, if_exists: true
  end
end
