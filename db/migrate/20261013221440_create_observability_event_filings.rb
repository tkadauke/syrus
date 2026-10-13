class CreateObservabilityEventFilings < ActiveRecord::Migration[8.1]
  def change
    create_table :observability_event_filings do |t|
      t.string :event_type, null: false
      t.integer :event_id, null: false
      t.references :job, foreign_key: true
      t.text :issue_url
      t.string :mode, null: false
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :observability_event_filings, [ :event_type, :event_id ], unique: true
  end
end
