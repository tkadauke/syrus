class CreateRunFailureClassifications < ActiveRecord::Migration[8.1]
  def up
    create_table :run_failure_classifications, if_not_exists: true do |t|
      t.references :run, null: false, foreign_key: true, index: { unique: true }
      t.string :classification, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.boolean :retryable, null: false
      t.text :reason
      t.text :diagnostic_summary
      t.text :classifier_inputs
      t.datetime :classified_at

      t.timestamps
    end

    add_index :run_failure_classifications, :classification unless index_exists?(:run_failure_classifications, :classification)
    add_index :run_failure_classifications, :retryable unless index_exists?(:run_failure_classifications, :retryable)
    add_index :run_failure_classifications, :classified_at unless index_exists?(:run_failure_classifications, :classified_at)
  end

  def down
    drop_table :run_failure_classifications, if_exists: true
  end
end
