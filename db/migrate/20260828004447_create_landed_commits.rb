class CreateLandedCommits < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:landed_commits)
      create_table :landed_commits do |t|
        t.references :landable, polymorphic: true, null: false
        t.string :sha, null: false
        t.string :kind, null: false
        t.integer :position, null: false, default: 0
        t.timestamps
      end

      add_index :landed_commits, :sha, unique: true unless index_exists?(:landed_commits, :sha)
      unless index_exists?(:landed_commits, [ :landable_type, :landable_id, :position ])
        add_index :landed_commits, [ :landable_type, :landable_id, :position ]
      end
    end
  end

  def down
    drop_table :landed_commits if table_exists?(:landed_commits)
  end
end
