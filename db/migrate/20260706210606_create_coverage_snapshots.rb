class CreateCoverageSnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :coverage_snapshots, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true, index: true
      t.references :workflow,   null: false, foreign_key: true
      t.references :job,        null: true,  foreign_key: true

      t.string  :sha,    null: false
      t.string  :branch, null: false

      t.decimal :lines_pct,     precision: 5, scale: 2
      t.decimal :branches_pct,  precision: 5, scale: 2
      t.decimal :functions_pct, precision: 5, scale: 2
      t.decimal :pr_delta_pct,  precision: 5, scale: 2

      t.integer :file_count

      # Per-file summary: { "app/models/user.rb" => { "lines_pct" => 95.2, "branches_pct" => 88.0 } }
      # MySQL 8 does not support JSON defaults — seeded to {} via after_initialize on the model.
      t.json :data

      t.timestamps
    end

    add_index :coverage_snapshots, [ :repository_id, :created_at ] unless index_exists?(:coverage_snapshots, [ :repository_id, :created_at ])
    add_index :coverage_snapshots, [ :repository_id, :branch ]     unless index_exists?(:coverage_snapshots, [ :repository_id, :branch ])
  end

  def down
    drop_table :coverage_snapshots, if_exists: true
  end
end
