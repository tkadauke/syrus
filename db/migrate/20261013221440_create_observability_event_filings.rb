class CreateObservabilityEventFilings < ActiveRecord::Migration[8.1]
  def change
    create_table :observability_event_filings, if_not_exists: true do |t|
      t.string :event_type, null: false
      t.integer :event_id, null: false
      t.references :job, foreign_key: false
      t.text :issue_url
      t.string :mode, null: false
      t.references :user, null: false, foreign_key: false

      t.timestamps
    end

    unless index_exists?(:observability_event_filings, [ :event_type, :event_id ])
      add_index :observability_event_filings, [ :event_type, :event_id ], unique: true
    end
  end
end
