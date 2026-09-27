class CreateOperatorBriefingFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_briefing_items, if_not_exists: true do |t|
      t.bigint :briefing_id
      t.string :severity, null: false
      t.string :source_type
      t.bigint :source_id
      t.text :narrative, null: false
      t.json :evidence

      t.timestamps
    end

    add_index :operator_briefing_items, :briefing_id unless index_exists?(:operator_briefing_items, :briefing_id)
    unless index_exists?(:operator_briefing_items, [ :source_type, :source_id ], name: "idx_operator_briefing_items_source")
      add_index :operator_briefing_items,
                [ :source_type, :source_id ],
                name: "idx_operator_briefing_items_source"
    end
    unless index_exists?(:operator_briefing_items, [ :severity, :created_at ], name: "idx_operator_briefing_items_severity")
      add_index :operator_briefing_items,
                [ :severity, :created_at ],
                name: "idx_operator_briefing_items_severity"
    end
  end
end
