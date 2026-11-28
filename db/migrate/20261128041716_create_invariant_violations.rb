# The invariant monitor's record of each ongoing violation: one row per
# violation episode, opened the first time a fingerprint is seen and resolved
# once it stops appearing. `open_fingerprint` mirrors `fingerprint` while the
# row is open and is NULL once resolved, so the unique index admits exactly
# one open row per fingerprint and any number of resolved ones.
class CreateInvariantViolations < ActiveRecord::Migration[8.1]
  def up
    create_table :invariant_violations, if_not_exists: true do |t|
      t.string :invariant_key, limit: 64, null: false
      t.string :fingerprint, limit: 255, null: false
      t.string :open_fingerprint, limit: 255
      t.string :severity, limit: 16, null: false
      t.string :subject_type, limit: 64, null: false
      t.bigint :subject_id
      t.json :message_params
      t.json :details
      t.json :affected_ids
      t.datetime :violating_since
      t.datetime :first_detected_at, null: false
      t.datetime :last_detected_at, null: false
      t.datetime :resolved_at
      t.integer :detection_count, null: false, default: 1
      t.timestamps
    end

    add_index :invariant_violations, :open_fingerprint, unique: true unless index_exists?(:invariant_violations, :open_fingerprint)
    add_index :invariant_violations, [ :resolved_at, :invariant_key ] unless index_exists?(:invariant_violations, [ :resolved_at, :invariant_key ])
    add_index :invariant_violations, [ :subject_type, :subject_id ] unless index_exists?(:invariant_violations, [ :subject_type, :subject_id ])
  end

  def down
    drop_table :invariant_violations, if_exists: true
  end
end
