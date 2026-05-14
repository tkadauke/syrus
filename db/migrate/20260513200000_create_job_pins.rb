class CreateJobPins < ActiveRecord::Migration[8.1]
  def change
    create_table :job_pins do |t|
      t.references :user, null: false, foreign_key: true
      t.references :job, null: false, foreign_key: true

      t.timestamps
    end

    add_index :job_pins, [ :user_id, :job_id ], unique: true
    add_index :job_pins, [ :user_id, :created_at ]
  end
end
